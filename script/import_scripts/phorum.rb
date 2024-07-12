# frozen_string_literal: true

require "mysql2"
require "htmlentities"

begin
  require "php_serialize" # https://github.com/jqr/php-serialize
rescue LoadError
  puts
  puts "php_serialize not found."
  puts "Add to Gemfile, like this: "
  puts
  puts "echo gem \\'php-serialize\\' >> Gemfile"
  puts "bundle install"
  exit
end

require File.expand_path(File.dirname(__FILE__) + "/base.rb")

class ImportScripts::Phorum < ImportScripts::Base
  PHORUM_DB = "phorum"
  TABLE_PREFIX = "phorum_"
  # Set to non-empty value ending with "/" for permalinks.
  # If using example.com/forum, the value should be "forum/"
  BASE = "phorum/"
  BATCH_SIZE = 1000

  def initialize
    super

    @htmlentities = HTMLEntities.new
    @client =
      Mysql2::Client.new(
        host: "localhost",
        username: "root",
        password: "",
        database: PHORUM_DB,
      )
    # Example of importing a custom profile field, uncomment if needed
    # First, create the field itself
    @custom_field = UserField.find_by_name("Geocaching ID")
    unless @custom_field
      @custom_field = UserField.create(name: "Geocaching ID", description: "ID in Geocacahing", field_type: "text", editable: false, required: false, show_on_profile: true, show_on_user_card: true)
    end

  end

  def tune_site_settings
    SiteSetting.unicode_usernames = true
  end

  def execute
    tune_site_settings
    import_categories
    import_users
    import_private_messages
    import_posts
    import_attachments
    create_permalinks
  end

  def import_users
    puts "", "creating users"

    total_count = mysql_query("SELECT count(*) count FROM #{TABLE_PREFIX}users;").first["count"]

    batches(BATCH_SIZE) do |offset|
      results =
        mysql_query(
          "SELECT user_id id, username, TRIM(email) AS email, username name, date_added created_at,
                date_last_active last_seen_at, admin, uid
         FROM #{TABLE_PREFIX}users
         WHERE #{TABLE_PREFIX}users.active = 1
         LIMIT #{BATCH_SIZE}
         OFFSET #{offset};",
        )

      break if results.size < 1

      create_users(results, total: total_count, offset: offset) do |user|
        next if user["username"].blank?
        next if @lookup.user_id_from_imported_user_id(user["id"])
        {
          id: user["id"],
          email: user["email"],
          username: user["username"],
          name: user["name"],
          created_at: Time.zone.at(user["created_at"]),
          last_seen_at: Time.zone.at(user["last_seen_at"]),
          admin: user["admin"] == 1,
          custom_fields: {"user_field_#{@custom_field.id}" => user["uid"]},
        }
      end   
    end
  end


  def create_permalinks
    puts "", "Creating redirects...", ""

    puts "", "Users...", ""
    User.find_each do |u|
      ucf = u.custom_fields
      if ucf && ucf["import_id"] && ucf["import_username"]
        begin
          Permalink.find_or_create_by(url: "#{BASE}profile.php?1,#{ucf["import_id"]}", external_url: "/u/#{u.username}")
        rescue StandardError
          nil
        end
        
        print_warning("#{BASE}profile.php?1,#{ucf["import_id"]} -> /u/#{u.username}")
        print "."
      end
    end  

    def print_warning(message)
      $stderr.puts "#{message}"
    end
end

  def import_categories
    puts "", "importing categories..."

    categories =
      mysql_query(
        "
                              SELECT forum_id id, name, description, active
                              FROM #{TABLE_PREFIX}forums
                              ORDER BY forum_id ASC
                            ",
      ).to_a

    create_categories(categories) do |category|
      next if category["active"] == 0
      { id: category["id"], name: category["name"], description: category["description"] }
    end

    # uncomment below lines to create permalink
    categories.each do |category|
      Permalink.find_or_create_by(url: "#{BASE}list.php?#{category['id']}", category_id: category_id_from_imported_category_id(category['id'].to_i))
    end
  end

  def import_posts
    puts "", "creating topics and posts"

    total_count = mysql_query("SELECT count(*) count from #{TABLE_PREFIX}messages").first["count"]

    batches(BATCH_SIZE) do |offset|
      results =
        mysql_query(
          "
        SELECT m.message_id id,
               m.parent_id,
               m.forum_id category_id,
               m.subject title,
               m.user_id user_id,
               m.body raw,
               m.closed closed,
               m.datestamp created_at
        FROM #{TABLE_PREFIX}messages m
        ORDER BY m.datestamp
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset};
      ",
        ).to_a

      break if results.size < 1

      create_posts(results, total: total_count, offset: offset) do |m|
        skip = false
        mapped = {}

        mapped[:id] = m["id"]
        mapped[:user_id] = user_id_from_imported_user_id(m["user_id"]) || -1
        mapped[:created_at] = Time.zone.at(m["created_at"])

        if m["parent_id"] == 0
          mapped[:category] = category_id_from_imported_category_id(m["category_id"].to_i)
          mapped[:title] = CGI.unescapeHTML(m["title"])
        else
          parent = topic_lookup_from_imported_post_id(m["parent_id"])
          if parent
            mapped[:topic_id] = parent[:topic_id]
          else
            puts "Parent post #{m["parent_id"]} doesn't exist. Skipping #{m["id"]}: #{m["title"][0..40]}"
            skip = true
          end
          if m["title"] && !m["title"].start_with?("Re:")
            m["raw"] = "**#{m["title"]}**\n\n#{m["raw"]}"
          end
        end
        mapped[:raw] = process_raw_post(m["raw"], m["id"])

        skip ? nil : mapped
      end

      # uncomment below lines to create permalink
      results.each do |post|
        if post['parent_id'] == 0
          topic = topic_lookup_from_imported_post_id(post['id'].to_i)
          Permalink.create(url: "#{BASE}read.php?#{post['category_id']},#{post['id']}", topic_id: topic[:topic_id].to_i)
        end
      end
    end
  end

  
  def import_private_messages
    puts "", "creating private messages"

    total_count = mysql_query("SELECT count(*) count from #{TABLE_PREFIX}pm_messages").first["count"]

    batches(BATCH_SIZE) do |offset|
      results =
        mysql_query(
          "
        SELECT m.pm_message_id id,
               m.subject title,
               m.message message,
               m.from_user_id user_id,
               m.meta meta,
               m.datestamp created_at
        FROM #{TABLE_PREFIX}pm_messages m
        ORDER BY m.datestamp
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset};
      ",
        ).to_a

      break if results.size < 1
      results.reject! { |pm| @lookup.post_already_imported?("pm-#{pm["id"]}") }
      title_username_of_pm_first_post = {}

      create_posts(results, total: total_count, offset: offset) do |m|
        skip = false
        mapped = {}

        mapped[:id] = "pm-#{m["id"]}"
        title = @htmlentities.decode(m["title"]).strip[0...255]
        mapped[:user_id] = user_id_from_imported_user_id(m["user_id"]) || -1
        mapped[:raw] = process_raw_post(m["message"], m["id"])
        mapped[:created_at] = Time.zone.at(m["created_at"])

        
        target_usernames = []
        target_userids = []
        begin
          to_user_array = PHP.unserialize(m["meta"])["recipients"]
        rescue StandardError
          puts "#{m["id"]} -- #{m["meta"]}"
          skip = true
        end
        
        begin
          # The key is the ID of the user, so we only need key
          to_user_array.each do |to_user, user_hash|
            #puts "Looking for user #{to_user}..."
            user_id = user_id_from_imported_user_id(to_user)
            username = User.find_by(id: user_id).try(:username)
            target_userids << user_id || Discourse::SYSTEM_USER_ID
            target_usernames << username if username
            #puts "Found #{username} with Discourse ID #{user_id}"
          end
        rescue StandardError
          puts "skipping pm-#{m["id"]} `to_user_array` is not properly serialized -- #{to_user_array.inspect}"
          skip = true
        end

        participants = target_userids
        participants << mapped[:user_id]
        begin
          participants.sort!
        rescue StandardError
          puts "one of the participant's id is nil -- #{participants.inspect}"
        end

        if title =~ /^Re:/
          parent_id =
            title_username_of_pm_first_post[[title[3..-1], participants]] ||
              title_username_of_pm_first_post[[title[4..-1], participants]] ||
              title_username_of_pm_first_post[[title[5..-1], participants]] ||
              title_username_of_pm_first_post[[title[6..-1], participants]] ||
              title_username_of_pm_first_post[[title[7..-1], participants]] ||
              title_username_of_pm_first_post[[title[8..-1], participants]]

          if parent_id
            if t = topic_lookup_from_imported_post_id("pm-#{parent_id}")
              topic_id = t[:topic_id]
            end
          end
        else
          title_username_of_pm_first_post[[title, participants]] ||= m["id"]
        end
        if topic_id
          mapped[:topic_id] = topic_id
        else
          mapped[:title] = title
          mapped[:archetype] = Archetype.private_message
          mapped[:target_usernames] = target_usernames.join(",")

          if mapped[:target_usernames].size < 1 # pm with yourself?
            # skip = true
            mapped[:target_usernames] = "system"
          puts "pm-#{m["id"]} has no target (#{to_user_array.inspect})"
          end
        end

        skip ? nil : mapped
      end

    end
  end

  def process_raw_post(raw, import_id)
    s = raw.dup

    # :) is encoded as <!-- s:) --><img src="{SMILIES_PATH}/icon_e_smile.gif" alt=":)" title="Smile" /><!-- s:) -->
    s.gsub!(%r{<!-- s(\S+) --><img (?:[^>]+) /><!-- s(?:\S+) -->}, '\1')

    # Some links look like this: <!-- m --><a class="postlink" href="http://www.onegameamonth.com">http://www.onegameamonth.com</a><!-- m -->
    s.gsub!(%r{<!-- \w --><a(?:.+)href="(\S+)"(?:.*)>(.+)</a><!-- \w -->}, '[\2](\1)')

    # Many phpbb bbcode tags have a hash attached to them. Examples:
    #   [url=https&#58;//google&#46;com:1qh1i7ky]click here[/url:1qh1i7ky]
    #   [quote=&quot;cybereality&quot;:b0wtlzex]Some text.[/quote:b0wtlzex]
    s.gsub!(/:(?:\w{8})\]/, "]")

    # Remove mybb video tags.
    s.gsub!(%r{(^\[video=.*?\])|(\[/video\]$)}, "")

    s = CGI.unescapeHTML(s)

    # phpBB shortens link text like this, which breaks our markdown processing:
    #   [http://answers.yahoo.com/question/index ... 223AAkkPli](http://answers.yahoo.com/question/index?qid=20070920134223AAkkPli)
    #
    # Work around it for now:
    s.gsub!(%r{\[http(s)?://(www\.)?}, "[")

    # [QUOTE]...[/QUOTE]
    # Seems no need in this, Discourse recognizes "quote" normally,
    # it only needs to be on the new lines (which will be handled by the next line)
    #s.gsub!(%r{\[quote\](.+?)\[/quote\]}im) { "\n> #{$1}\n" }

    # Nested Quotes
    s.gsub!(%r{(\[/?QUOTE.*?\])}mi) { |q| "\n#{q}\n" }

    # [QUOTE=username]
    s.gsub!(/\[quote=(.*?)\]/i) do
      username = $1

      "\n[quote=\"#{username}\"]\n"
    end

    # [size=...]...[/size]
    s.gsub!(%r{\[size=large\](.+)\[/size\]}i) { "<big>#{$1}</big>" }
    s.gsub!(%r{\[size=x.large\](.+)\[/size\]}i) { "<big>#{$1}</big>" }
    s.gsub!(%r{\[size=medium\](.+)\[/size\]}i) { "#{$1}" }
    s.gsub!(%r{\[size=small\](.+)\[/size\]}i) { "<small>#{$1}</small>" }
    s.gsub!(%r{\[size=x.small\](.+)\[/size\]}i) { "<small>#{$1}</small>" }

    # [spoiler]...[/spoiler] is not Discourse Spoiler, but details
    s.gsub!(%r{\[spoiler=(.+?)\](.+)\[/spoiler\]}i) { "[details=#{$1}](#{$2})[/details]" }
    s.gsub!(%r{\[spoiler\](.+)\[/spoiler\]}i) { "[details](#{$1})[/details]" }

    # [URL=...]...[/URL]
    s.gsub!(%r{\[url="?(.+?)"?\](.+)\[/url\]}i) { "[#{$2}](#{$1})" }

    # [IMG]...[/IMG]
    # Do not strip images
    #s.gsub!(%r{\[/?img\]}i, "")

    # convert list tags to ul and list=1 tags to ol
    # (basically, we're only missing list=a here...)
    s.gsub!(%r{\[list\](.*?)\[/list\]}m, '[ul]\1[/ul]')
    s.gsub!(%r{\[list=1\](.*?)\[/list\]}m, '[ol]\1[/ol]')
    # convert *-tags to li-tags so bbcode-to-md can do its magic on phpBB's lists:
    s.gsub!(/\[\*\](.*?)\n/, '[li]\1[/li]')

    # [CODE]...[/CODE]
    s.gsub!(%r{\[/?code\]}i, "\n```\n")
    # [HIGHLIGHT]...[/HIGHLIGHT]
    s.gsub!(%r{\[/?highlight\]}i, "\n```\n")

    # [YOUTUBE]<id>[/YOUTUBE]
    s.gsub!(%r{\[youtube\](.+?)\[/youtube\]}i) { "\nhttps://www.youtube.com/watch?v=#{$1}\n" }

    # [youtube=425,350]id[/youtube]
    s.gsub!(%r{\[youtube="?(.+?)"?\](.+)\[/youtube\]}i) do
      "\nhttps://www.youtube.com/watch?v=#{$2}\n"
    end

    # [MEDIA=youtube]id[/MEDIA]
    s.gsub!(%r{\[MEDIA=youtube\](.+?)\[/MEDIA\]}i) { "\nhttps://www.youtube.com/watch?v=#{$1}\n" }

    # [ame="youtube_link"]title[/ame]
    s.gsub!(%r{\[ame="?(.+?)"?\](.+)\[/ame\]}i) { "\n#{$1}\n" }

    # [VIDEO=youtube;<id>]...[/VIDEO]
    s.gsub!(%r{\[video=youtube;([^\]]+)\].*?\[/video\]}i) do
      "\nhttps://www.youtube.com/watch?v=#{$1}\n"
    end

    # [USER=706]@username[/USER]
    s.gsub!(%r{\[user="?(.+?)"?\](.+)\[/user\]}i) { $2 }

    # Remove the color tag as it's not supported
    s.gsub!(/\[color=[#a-z0-9]+\]/i, "")
    s.gsub!(%r{\[/color\]}i, "")

    s.gsub!(/\[hr\]/i, "<hr>")

    # remove trailing <br>
    s = s.chomp("<br>")

    s
  end

  def mysql_query(sql)
    @client.query(sql, cache_rows: false)
  end

  def import_attachments
    puts "", "importing attachments..."

    uploads = mysql_query <<-SQL
      SELECT message_id, filename, FROM_BASE64(file_data) AS file_data, file_id
      FROM #{TABLE_PREFIX}files
      where message_id > 0
      order by file_id
    SQL

    current_count = 0
    total_count = uploads.count

    uploads.each do |upload|
      # puts "*** processing file #{upload['file_id']}"

      post_id = post_id_from_imported_post_id(upload["message_id"])

      if post_id.nil?
        puts "Post #{upload["message_id"]} for attachment #{upload["file_id"]} not found"
        next
      end

      post = Post.find(post_id)

      real_filename = upload["filename"]
      real_filename.prepend SecureRandom.hex if real_filename[0] == "."

      tmpfile = "attach_" + upload["file_id"].to_s
      filename = File.join("/tmp/", tmpfile)
      File.open(filename, "wb") { |f| f.write(upload["file_data"]) }

      upl_obj = create_upload(post.user.id, filename, real_filename)

      # puts "discourse post #{post['id']} and upload #{upl_obj['id']}"

      if upl_obj&.persisted?
        html = html_for_upload(upl_obj, real_filename)
        if !post.raw[html]
          post.raw += "\n\n#{html}\n\n"
          post.save!
          if UploadReference.where(target: post, upload: upl_obj).exists?
            puts "skipping creating uploaded for previously uploaded file #{upload["file_id"]}"
          else
            UploadReference.ensure_exist!(upload_ids: [upl_obj.id], target: post)
          end
          # PostUpload.create!(post: post, upload: upl_obj) unless PostUpload.where(post: post, upload: upl_obj).exists?
        else
          puts "Skipping attachment #{upload["file_id"]}"
        end
      else
        puts "Failed to upload attachment #{upload["file_id"]}"
        exit
      end

      current_count += 1
      print_status(current_count, total_count)
    end
  end
end

ImportScripts::Phorum.new.perform
