defmodule Mix.Tasks.PhoenixPostgresPubSub.Gen.Channel do
  use Mix.Task

  import Macro, only: [camelize: 1, underscore: 1]
  import Mix.Generator
  import Mix.Ecto
  import Mix.EctoSQL

  @shortdoc "Generates a new migration to listen on a Postgres channel"

  @moduledoc """
  Generates a migration to listen to changes in postgres.
  The repository must be set under `:ecto_repos` in the
  current app configuration or given via the `-r` option.
  ## Examples
      mix ecto.gen.migration listen_to_member_changes --table=members
      mix ecto.gen.migration listen_to_member_changes --table=members --repo=Custom.Repo
  The generated migration filename will be prefixed with the current
  timestamp in UTC which is used for versioning and ordering.
  By default, the migration will be generated to the
  "priv/YOUR_REPO/migrations" directory of the current application
  but it can be configured to be any subdirectory of `priv` by
  specifying the `:priv` key under the repository configuration.
  This generator will automatically open the generated file if
  you have `ECTO_EDITOR` set in your environment variable.
  ## Command line options
    * `-r`, `--repo` - the repo to generate migration for
    * `-t`, `--table` - the table to listen the notifications migration for
  """

  @switches [table: :string]

  @doc false
  def run(args) do
    no_umbrella!("phoenix_postgres_pubsub.gen.channel")
    repos = parse_repo(args)

    Enum.map(repos, fn repo ->
      case OptionParser.parse(args, switches: @switches) do
        {opts, [name], _} ->
          ensure_repo(repo, args)
          path = Path.join(source_repo_priv(repo), "migrations")
          base_name = "#{underscore(name)}.exs"
          file = Path.join(path, "#{timestamp()}_#{base_name}")
          unless File.dir?(path), do: create_directory(path)

          fuzzy_path = Path.join(path, "*_#{base_name}")

          if Path.wildcard(fuzzy_path) != [] do
            Mix.raise(
              "migration can't be created, there is already a migration file with name #{name}."
            )
          end

          table_name =
            opts[:table] ||
              Mix.raise(
                "migration can't be created, you need to pass the argument table_name (i.e. --table_name=users)."
              )

          assigns = [
            mod: Module.concat([repo, Migrations, camelize(name)]),
            table_name: table_name
          ]

          create_file(file, migration_template(assigns))

          file

        {_, _, _} ->
          Mix.raise(
            "expected phoenix_postgres_pubsub.gen.channel to receive the migration file name, " <>
              "got: #{inspect(Enum.join(args, " "))}"
          )
      end
    end)
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i) when i < 10, do: <<?0, ?0 + i>>
  defp pad(i), do: to_string(i)

  embed_template(:migration, """
  defmodule <%= inspect @mod %> do
    use Ecto.Migration
    def change do
    execute("
            CREATE OR REPLACE FUNCTION broadcast_<%= @table_name %>_changes()
            RETURNS trigger AS $$
            DECLARE
              current_row RECORD;
            BEGIN
              IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') THEN
                current_row := NEW;
              ELSE
                current_row := OLD;
              END IF;
              IF (TG_OP = 'INSERT') THEN
                OLD := NEW;
              END IF;
            PERFORM pg_notify(
                '<%= @table_name %>_changes',
                json_build_object(
                  'table', TG_TABLE_NAME,
                  'type', TG_OP,
                  'id', current_row.id
                )::text
              );
            RETURN current_row;
            END;
            $$ LANGUAGE plpgsql;")

    execute("
            CREATE TRIGGER notify_<%= @table_name %>_changes_trigger
            AFTER INSERT OR UPDATE
            ON <%= @table_name %>
            FOR EACH ROW EXECUTE PROCEDURE broadcast_<%= @table_name %>_changes();")
    end
  end
  """)
end
