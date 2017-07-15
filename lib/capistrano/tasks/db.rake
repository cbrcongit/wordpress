namespace :evolve do
  namespace :db do
    task :prepare, :source, :target do |task, args|
      def filter_stage(stage)
        if stage == 'production'
          return (fetch(:www) ? 'www.' : '') + fetch(:domain)
        else
          return stage + '.' + fetch(:domain)
        end
      end

      stage_source = args[:source].to_s
      stage_target = args[:target].to_s

      invoke "evolve:calc_wp_path", stage_target == 'local'

      set :wp_cmd, [
        "\"://#{filter_stage(stage_source)}/\"",
        "\"://#{filter_stage(stage_target)}/\"",
        "--path=\"#{fetch(:working_wp_path)}\"",
        "--url=\"http://#{stage_target}.#{fetch(:domain)}/\"",
      ].join(' ')
    end

    desc "Create backup of remote DB"
    task :backup, :skip_download do |task, args|
      set :db_backup_file, DateTime.now.strftime("#{fetch(:wp_config)['name']}.%Y-%m-%d.%H%M%S.sql")
      set :db_gzip_file, "#{fetch(:db_backup_file)}.gz"

      invoke "evolve:calc_wp_path", false

      on release_roles(:db) do |host|
        backups_path = "#{deploy_to}/backups"
        execute :mkdir, '-p', backups_path

        within backups_path do
          execute :wp, :db, :export, fetch(:db_backup_file), "--opt", "--path=\"#{fetch(:working_wp_path)}\"", "--url=\"http://#{fetch(:stage)}.#{fetch(:domain)}/\""
          execute :gzip, fetch(:db_backup_file)

          if args[:skip_download]
            backups = capture(:ls, '-x', backups_path).split
            if backups.count >= fetch(:keep_releases)
              info 'Keeping %s of %s database backups on %s' % [ fetch(:keep_releases), backups.count, host.to_s ]
              files = (backups - backups.last(fetch(:keep_releases)))
              if files.any?
                files_str = files.map do |backup|
                  backups_path + '/' + backup
                end.join(' ')
                execute :rm, '-rf', files_str
              else
                info 'No old database backups (keeping newest %s) on %s' % [ fetch(:keep_releases), host.to_s ]
              end
            end
          else
            download! "#{backups_path}/#{fetch(:db_gzip_file)}", fetch(:db_gzip_file)
            execute :rm, fetch(:db_gzip_file)
          end

        end
      end
    end

    task :import, :sql_file, :source_stage, :target_stage do |task, args|
      source_stage = args[:source_stage].to_s
      target_stage = args[:target_stage].to_s
      # if crossing stages, invoke prepare task to build wp search-replace command
      cross_stage = target_stage != source_stage
      if cross_stage
        invoke "evolve:db:prepare", source_stage, target_stage
      # otherwise just invoke calc_wp_path task to...calculate working wp path
      else
        invoke "evolve:calc_wp_path", target_stage == 'local'
      end
      if target_stage == "local"
        run_locally do
          sql_file = args[:sql_file]
          if sql_file.start_with?(Dir.pwd)
            sql_file.sub!(Dir.pwd, '/vagrant')
          end
          execute :vagrant, :up
          execute :vagrant, :ssh, :local,  "-c 'cd /vagrant && mysql -uroot -D \"#{fetch(:wp_config)['name']}_local\" < #{sql_file}'"
          if cross_stage
            execute :vagrant, :ssh, :local, "-c 'cd #{fetch(:working_wp_path)} && wp search-replace #{fetch(:wp_cmd)}'"
          end
        end
      else
        on release_roles(:db) do
          within fetch(:working_wp_path) do
            execute :wp, :db, :import, args[:sql_file], "--path=\"#{fetch(:working_wp_path)}\"", "--url=\"http://#{fetch(:stage)}.#{fetch(:domain)}/\""
            if cross_stage
              execute :wp, :'search-replace', fetch(:wp_cmd)
            end
          end
        end
      end
    end

    task :down do |task|
      begin
        raise "Cannot sync db down from local!" if fetch(:stage).to_s == 'local'

        invoke "evolve:db:backup"

        run_locally do
          execute :gzip, "-d", fetch(:db_gzip_file)
          invoke "evolve:db:import", fetch(:db_backup_file), fetch(:stage), "local"
          execute :rm, fetch(:db_backup_file)
        end

        success=true
      ensure
        invoke "evolve:log", success, task.name
      end
    end

    task :up do |task|
      begin
        raise "Cannot sync db up to local!" if fetch(:stage).to_s == 'local'

        invoke "evolve:confirm", "You are about to destroy & override the \"#{fetch(:stage)}\" database!"
        invoke "evolve:db:backup", true

        run_locally do
          execute :vagrant, :up
          execute :vagrant, :ssh, :local, "-c 'cd /vagrant && mysqldump -uroot --opt \"#{fetch(:wp_config)['name']}_local\" > #{fetch(:db_backup_file)}'"
          execute :gzip, fetch(:db_backup_file)
        end

        on release_roles(:db) do
          upload! fetch(:db_gzip_file), "/tmp/#{fetch(:db_gzip_file)}"
          execute :gzip, "-d", "/tmp/#{fetch(:db_gzip_file)}"

          invoke "evolve:db:import", "/tmp/#{fetch(:db_backup_file)}", "local", fetch(:stage)

          execute :rm, "/tmp/#{fetch(:db_backup_file)}"
        end

        run_locally do
          execute :rm, fetch(:db_gzip_file)
        end

        success=true
      ensure
        invoke "evolve:log", success, task.name
      end
    end

    task :exec, :sql_file do |task, args|
      begin
        raise "Missing sql file!" if args[:sql_file].nil?
        raise "Given sql file does not exist: #{args[:sql_file]}" unless File.exist?(args[:sql_file])
        sql_size = File.size(args[:sql_file])

        invoke "evolve:confirm", "You are about to execute a sql file against \"#{fetch(:stage)}\" database!"

        on release_roles(:db) do
          remote_sql_file = "/tmp/" + DateTime.now.strftime("wpe-exec.%Y-%m-%d.%H%M%S.sql")
          upload! args[:sql_file], remote_sql_file

          # fetch unmodified max_allowed_packet, then crank it up for import
          original_map = capture(:mysql, '-uroot', '-NBe', '"SELECT @@GLOBAL.max_allowed_packet"')
          execute :mysql, '-uroot', '-NBe', "\"SET @@GLOBAL.max_allowed_packet=#{sql_size}\""

          # import sql file, then delete it
          execute :mysql, '-uroot', "-D \"#{fetch(:wp_config)['name']}_#{fetch(:stage)}\"", "< #{remote_sql_file}"
          execute :rm, remote_sql_file

          # reset max_allowed_packet
          execute :mysql, '-uroot', '-NBe', "'SET @@GLOBAL.max_allowed_packet=#{original_map}'"
        end

        success=true
      ensure
        invoke "evolve:log", success, task.name
      end
    end
  end
end
