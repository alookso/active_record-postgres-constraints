# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActiveRecord::Postgres::Constraints do
  it 'has a version number' do
    expect(described_class::VERSION).not_to be nil
  end

  context 'when a migration adds a constraint' do
    def dummy_dir
      File.expand_path('../../../dummy', __FILE__)
    end

    def migration_dir
      "#{dummy_dir}/db/migrate/"
    end

    def delete_all_migration_files
      `rm -rf #{migration_dir}/*.rb`
    end

    def cleanup_database
      delete_all_migration_files
      ActiveRecord::Tasks::DatabaseTasks.drop_current
      ActiveRecord::Tasks::DatabaseTasks.create_current
    end

    def migration_file(migration_number, suffix)
      migration_file_name = "#{migration_number}_migration_#{suffix}"
      "#{migration_dir}/#{migration_file_name}.rb"
    end

    def migration_content(migration_name_suffix)
      <<-MIGRATION_CLASS.strip_heredoc
      class Migration#{migration_name_suffix} < ActiveRecord::Migration[5.0]
        def change\n#{yield.strip_heredoc.indent(10).rstrip}
        end
      end
      MIGRATION_CLASS
    end

    def generate_migration(migration_number, suffix, &block)
      File.open(migration_file(migration_number, suffix), 'w') do |f|
        f.puts migration_content(suffix, &block)
      end
    end

    def schema_file
      "#{dummy_dir}/db/schema.rb"
    end

    def dump_schema
      require 'active_record/schema_dumper'
      File.open(schema_file, 'w:utf-8') do |file|
        ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection, file)
      end
    end

    def run_migrations
      if defined?(ActiveRecord::Base.connection.migration_context)
        ActiveRecord::Base.connection.migration_context.migrate
      else
        ActiveRecord::Tasks::DatabaseTasks.migrate
      end
      dump_schema
    end

    def rollback
      if defined?(ActiveRecord::MigrationContext)
        ActiveRecord::Base.connection.migration_context.rollback(1)
      else
        ActiveRecord::Migrator.rollback(
          ActiveRecord::Tasks::DatabaseTasks.migrations_paths, 1
        )
      end
      dump_schema
    end

    before do
      stub_const('Price', Class.new(ApplicationRecord))

      cleanup_database

      generate_migration('20170101120000', Random.rand(1..1000)) do
        content_of_change_method
      end

      run_migrations
    end

    after do
      rollback
      delete_all_migration_files
    end

    # rubocop:disable RSpec/BeforeAfterAll
    after(:all) do
      # rubocop:enable RSpec/BeforeAfterAll
      cleanup_database
      dump_schema
    end

    shared_examples_for 'adds a constraint' do
      let(:expected_schema_regex) do
        Regexp.escape <<-MIGRATION.strip_heredoc.indent(2)
          create_table "prices", #{'id: :serial, ' if Gem::Version.new(ActiveRecord.gem_version) >= Gem::Version.new('5.1.0')}force: :cascade do |t|
            t.integer "price"
            t.check_constraint :test_constraint, #{expected_constraint_string}
          end
        MIGRATION
      end

      it 'includes the check_constraint in the schema file' do
        schema = File.read(schema_file)
        expect(schema).to match expected_schema_regex
      end

      it 'enforces the constraint' do
        expect { Price.create! price: 999 }.to raise_error(
          ActiveRecord::StatementInvalid, expected_error_regex
        )
      end
    end

    let(:expected_constraint_error_message) do
      'PG::CheckViolation: ERROR:  new row for relation "prices" violates '\
        'check constraint "test_constraint"'
    end

    let(:expected_error_regex) { /\A#{expected_constraint_error_message}/ }

    context 'when using `t.check_constraint`' do
      let(:content_of_change_method) do
        <<-MIGRATION
          create_table :prices do |t|
            t.integer :price
            t.check_constraint :test_constraint, #{constraint}
          end
        MIGRATION
      end

      context 'when the constraint is a String' do
        let(:constraint) { "'price > 1000'" }
        let(:expected_constraint_string) { '"(price > 1000)"' }

        it_behaves_like 'adds a constraint'

        context 'when the constraint is anonymous' do
          let(:content_of_change_method) do
            <<-MIGRATION
              create_table :prices do |t|
                t.integer :price
                t.check_constraint   #{constraint}
              end
            MIGRATION
          end

          let(:expected_constraint_error_message) do
            'PG::CheckViolation: ERROR:  new row for relation "prices" '\
            'violates check constraint "prices_[0-9]{7,9}"'
          end

          it_behaves_like 'adds a constraint' do
            let(:expected_schema_regex) do
              Regexp.new <<-MIGRATION.strip_heredoc.indent(2)
                create_table "prices", force: :cascade do \|t\|
                  t.integer "price"
                  t.check_constraint :prices_[0-9]{7,9}, #{expected_constraint_string}
                end
              MIGRATION
            end
          end
        end
      end

      context 'when the constraint is a Hash' do
        let(:constraint) { { price: [10, 20, 30] } }
        let(:expected_constraint_string) do
          '"(price = ANY (ARRAY[10, 20, 30]))"'
        end

        it_behaves_like 'adds a constraint'
      end

      context 'when the constraint is an Array' do
        let(:constraint) { ['price > 50', { price: [90, 100] }] }
        let(:expected_constraint_string) do
          '"((price > 50) AND (price = ANY (ARRAY[90, 100])))"'
        end

        it_behaves_like 'adds a constraint'
      end
    end

    context 'when using add_check_constraint' do
      let(:constraint) { "'price > 1000'" }
      let(:expected_constraint_string) { '"(price > 1000)"' }
      let(:content_of_change_method) do
        <<-MIGRATION
          create_table :prices do |t|
            t.integer :price
          end
          add_check_constraint :prices, :test_constraint, #{constraint}
        MIGRATION
      end

      it_behaves_like 'adds a constraint'

      context 'when the constraint is removed in a later migration' do
        let(:content_of_change_method_for_removing_migration) do
          "remove_check_constraint :prices, :test_constraint, #{constraint}"
        end

        before do
          generate_migration('20170201120000', Random.rand(1001..2000)) do
            content_of_change_method_for_removing_migration
          end

          run_migrations
        end

        it 'removes the check_constraint from the schema file' do
          schema = File.read(schema_file)
          expect(schema).not_to match(/check_constraint/)
        end

        it 'enforces the constraint' do
          create_price = -> { Price.create! price: 999 }
          expect(create_price).not_to raise_error

          # Ensure that we can safely roll back the migration that removed the
          # check constraint
          Price.destroy_all

          rollback

          expect(create_price).to raise_error(ActiveRecord::StatementInvalid, expected_error_regex)
        end

        context 'when remove_check_constraint is irreversible' do
          let(:content_of_change_method_for_removing_migration) do
            'remove_check_constraint :prices, :test_constraint'
          end

          let(:expected_irreversible_migration_error_message) do
            'To make this migration reversible, pass the constraint to '\
              'remove_check_constraint, i.e. `remove_check_constraint, '\
              ":prices, :test_constraint, 'price > 999'`"
          end

          it 'removes the check_constraint from the schema file' do
            schema = File.read(schema_file)
            expect(schema).not_to match(/check_constraint/)
          end

          it 'enforces the constraint' do
            expect { Price.create! price: 999 }.not_to raise_error

            # Ensure that we can safely roll back the migration that removed the
            # check constraint
            Price.destroy_all
          end

          def rollback
            expect { super }.to raise_error StandardError,
              /#{expected_irreversible_migration_error_message}/m
          end
        end
      end
    end
  end
end
