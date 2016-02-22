
root_user = []
payload[:users].each do |user|
  if user[:username] == "root"
    root_user = user
    break
  end
end

# check for myisam tables
result = execute "check for MyISAM" do
  command <<-EOF
    /data/bin/mysql \
      -u root \
      --password=#{root_user[:password]} \
      -S /tmp/mysqld.sock \
      -e "SELECT count(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'gonano' AND ENGINE = 'MyISAM'\\G"
    EOF
end

myisam = false

result.match /count\(\*\): (.*)/ do |m|
  myisam = m[1].to_i > 0
end

execute "dump and upload to backup container" do
  command <<-EOF
    bash -c '/data/bin/mysqldump \
      #{(myisam) ? "--lock-all-tables" : "--single-transaction" } \
      --flush-privileges \
      --all-tablespaces \
      --add-drop-database \
      --add-drop-table \
      --create-options \
      --extended-insert \
      --routines \
      --triggers \
      -u root \
      --password=#{root_user[:password]} \
      -S /tmp/mysqld.sock \
      --databases gonano \
      | gzip \
        | tee >(md5sum | cut -f1 -d" " > /tmp/md5sum) \
          | ssh \
            -o StrictHostKeyChecking=no \
            #{payload[:backup][:local_ip]} \
            "cat > /data/var/db/mysql/#{payload[:backup][:backup_id]}.gz"
    for i in ${PIPESTATUS[@]}; do
      if [[ $i -ne 0 ]]; then
        exit $i
      fi
    done
    '
  EOF
end

remote_sum = `ssh -o StrictHostKeyChecking=no #{payload[:backup][:local_ip]} "md5sum /data/var/db/mysql/#{payload[:backup][:backup_id]}.gz"`.to_s.strip.split(' ').first

# Read POST results
local_sum = File.open('/tmp/md5sum') {|f| f.readline}.strip

# Ensure checksum match
if remote_sum != local_sum
  puts 'checksum mismatch'
  exit 1
end
