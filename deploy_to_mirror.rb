require 'rubygems'
require 'xmlsimple'
require 'open-uri'
require 'fileutils'
require 'nokogiri'
require 'optparse'
require 'yui/compressor'
require 'closure-compiler'
require 'yaml'
require 'aws-sdk'
require "benchmark"
require 'html_press'
require './deploy_lib/string'
require './deploy_lib/sitemap_generator'
require './deploy_lib/blog_feed_generator'
require './deploy_lib/file_writer'
require './deploy_lib/file_util'
require './deploy_lib/url_util'
require './deploy_lib/css_compressor'
require './deploy_lib/js_compressor'
require 'pry'

# TODO:
# Add scping of template header/footer to live vhost

#from httpdocs -> s3 command
#s3cmd sync --dry-run --exclude '*' --include '*.jpg, *.png, *.gif, *.svg, *.woff', *.ttf, *.eot' -P /var/www/vhosts/staging.discoverhawaiitours.com/httpdocs/wp-content/uploads s3://cdn.discoverhawaiitours.com/

DEBUG_DEPLOY = false
DEFAULT_BASE = 'http://staging.discoverhawaiitours.com/'

class Deploy

  attr_accessor :writer, :bucket_name, :base, :cdn_base, :link_base, :page_regex, :page_limit, :page_counter,
                :html_subs, :include_scripts, :exclude_scripts, :include_styles, :include_urls, :exclude_urls, 
                :css_compressor, :day_threshold

  def initialize
    hash_options = init_hash_options
    read_config_values
    @writer = FileWriter.new get_aws_bucket
    @page_counter = 0
    @page_regex = hash_options[:regex]
    @page_limit = hash_options[:limit].to_i
    @day_threshold = hash_options[:day_threshold]
    @html_cache = {}
    main
  end

  def init_hash_options
    hash_options = {}

    OptionParser.new do |o|
      o.on( '-r', '--page_regex [regex]', "regex matcher for base paths, ie 'activities,blog' or 'blogs'. Use / for only the base path, ie 'blog/'" ) do |f|
         hash_options[:regex] = f
      end
      o.on( '-l', '--page_limit [limit]', "maximum number of pages to generate" ) do |f|
         hash_options[:limit] = f
      end
      o.on( '-d', '--day_threshold [limit]', "maximum number of days to show pages modified from" ) do |f|
           hash_options[:day_threshold] = f
        end
      o.parse!
    end
    hash_options
  end

  def get_aws_bucket #returns the bucket object
    config_file = File.join(File.dirname(__FILE__),"deploy_config/s3.yml")
    config = YAML.load(File.read(config_file))
    AWS.config(config)
    b = AWS::S3.new.buckets[@bucket_name]
  end

  def read_config_values
    bases = URLUtil::read_config_file 'deploy_config/bases.yml', false
    @base = URLUtil::regulate_base(bases['staging']['base']) || DEFAULT_BASE
    @cdn_base = URLUtil::regulate_base(bases['mirror']['cdn_base']) || DEFAULT_BASE
    @link_base = URLUtil::regulate_base(bases['mirror']['base']) || DEFAULT_BASE
    @bucket_name = bases['mirror']['bucket_name']
    
    @html_subs = URLUtil::read_config_file 'deploy_config/html_subs', false
    @include_scripts = URLUtil::read_config_file 'deploy_config/include_scripts'
    @exclude_scripts = URLUtil::read_config_file 'deploy_config/exclude_scripts'
    @include_styles = URLUtil::read_config_file 'deploy_config/include_styles'
    @include_urls = URLUtil::read_config_file 'deploy_config/include_urls'
    @exclude_urls = URLUtil::read_config_file 'deploy_config/exclude_urls'
  end
  
  def main
    @csspressor = CSSCompressor.new @writer, @base, @cdn_base, @include_styles
    @jspressor = JSCompressor.new @writer, @base, @cdn_base, @link_base, @include_scripts, @exclude_scripts
    
    time = Benchmark.realtime { read_data }
    puts "\nFinished. Read the data in #{(time/60).round(2)} minutes.\n"
    
    if @page_counter > 0
      @csspressor.compress if @day_threshold.to_s.length == 0
      @jspressor.compress if @day_threshold.to_s.length == 0
      @html_cache.each_with_index { |(path,content)| @writer.write_file path.to_s, add_dynamic_stylesheets(content)}
      write_changed_images
      #{}%x{ssh -p 65000 ubuntu@www1.discoverhawaiitours.com 'sudo varnishadm -T 127.0.0.1:6082  -S /etc/varnish/secret "ban.url ."'}
      #puts "\nPurged varnish.\n"
      @writer.destroy #log written files
    else
      puts "No pages to process"
    end
  end
  
  def add_dynamic_stylesheets content
    style_head = ''
    @csspressor.sheet_count.times do |t|
      css_index = t ==  0 ? '' : t
      style_head << "<link rel=\"stylesheet\" href=\"#{@cdn_base}static/css/style#{css_index}.min.css\" />"
    end
    content.gsub('<!-- styles -->', style_head)
  end
  
  def read_data
     %x(rm -rf static/css/inline_css.css;rm -f static/css/inline_scripts.js)

     # generate latest sitemap.xml from staging
     xml_file = @base + '?sm_command=build&sm_key=158528cc6d5bdd75e96649bd54c3a8c0'
     xml = URLUtil::read_body(xml_file)
     
     xml_file = @base + 'sitemap.xml'
     puts "\nGetting url list from: #{xml_file}:\n"
     xml = URLUtil::read_body(xml_file)
     return if xml.to_s.size == 0

     data = XmlSimple.xml_in(xml)
     generate_sitemap data
     
     threshold_date = @day_threshold.to_s.length == 0 ? nil : (Date.today - @day_threshold.to_i)

     pass_urls = threshold_date.to_s.length == 0 ? [@base] : [] #for now, don't do homepage automatically when doing the threshold date
     pass_urls << URLUtil::filter_urls_by_regex(@include_urls.collect { |url| "#{base}#{url}" }, @page_regex)
     
     #include the blog homepage anytime you're talking about blog posts
     #the modified date on it might not be right
     pass_urls << "#{base}blog" if @day_threshold && @page_regex && @page_regex.to_s.include?('blog')
     generate_blog_feed if @page_regex.to_s.include?('blog') #generate the rss feed
    
     valid_date_urls = data['url'].select { |url| URLUtil::filter_url_by_modified_date(url, threshold_date)}
     
     pass_urls << URLUtil::filter_urls_by_regex(valid_date_urls.collect { |url| u = url['loc'].first.to_s.chomp('/') }, @page_regex)
     pass_urls = pass_urls.flatten.compact.uniq
     absolute_excludes = @exclude_urls.collect{ |u| @base + u }
     pass_urls = pass_urls.reject { |u| absolute_excludes.include? u}
     
     additional_attraction_urls = []
     pass_urls.each { |u| additional_attraction_urls << u + '/?template=basic' if u.include?('/attractions/') }
     pass_urls += additional_attraction_urls
     
     @page_limit = pass_urls.size unless @page_limit > 0 && pass_urls.size > @page_limit
     
     puts "\nThere are #{@page_limit} pages to be read. Gathering html...\n"
     pass_urls.each_with_index { |u,i| process_page u if(@page_counter < @page_limit)}
  end
  
  def generate_sitemap xml_data
    sitemap_options = {:base => @base, :rewrite_base => @link_base, :urls => xml_data['url'],
                        :include_urls => @include_urls, :exclude_urls => @exclude_Urls}
    SitemapGenerator.new(@writer, sitemap_options)
  end

  def generate_blog_feed
    sitemap_options = {:base => @base, :rewrite_base => @link_base}
    BlogFeedGenerator.new(@writer, sitemap_options)
  end
  
  def process_page url
     begin
       regulated_url = URLUtil::regulate_base(url)
       body = URLUtil::read_body(regulated_url)
       if body.to_s.size == 0
         puts "\ncould not open: #{url}\n"
         return false
       end
       giri_doc = Nokogiri::HTML(body)
       print("..#{@page_counter + 1}")
       @page_counter += 1
     rescue Exception => e
       error_message = "\ncould not open: "
       error_message += regulated_url.to_s.length != 0 ? regulated_url : url
       error_message << " because of #{e}\n"
       puts error_message
     end
     
     is_first_page = @page_counter == 1
     
     if giri_doc
       styles = @csspressor.get_srcs(giri_doc, url)
       scripts = @jspressor.get_srcs(giri_doc, url)
       html_content = process_html_elements(giri_doc, styles[:internal], scripts[:internal], scripts[:cdata], is_first_page)
       @html_cache[URLUtil::get_static_path(url).to_sym] = html_content
       
       #head_content = get_head_node(giri_doc).gsub('#maininner { width: 69%; }','#maininner { width: 100%; }')
       #write_static_tmpl "static_head.php", head_content if is_first_page
     end
  end
  
  def process_html_elements giri_doc, inline_styles, inline_scripts, cdata, is_first_page = false
    fix_element_paths(giri_doc, 'img, link') #image paths default to cdn base
    fix_element_paths(giri_doc, 'img', 'http://stage.discoverhawaiitours.com') #hack to fix old stage urls
    fix_element_paths(giri_doc, 'div, a, meta, form', @base, @link_base)
    remove_element_paths(giri_doc, '[rel="canonical"], [rel="EditURI"], [rel="wlwmanifest"], [rel="prev"], [rel="next"]')
    
    #inject new compressed css/js
    style_head = '<!-- styles -->' #insert style tags based on split css later
    script_head = "<script src=\"#{cdn_base}static/js/app.min.js\"></script>"
    inline_style_head = inline_styles.nil? ? '' : "<style>#{inline_styles}</style>"
    inline_script_head = inline_scripts.to_s.strip.length == 0 ? '' : "<script type=\"text/javascript\">#{inline_scripts}</script>"
    inline_cdata_head = cdata.to_s.strip.length == 0 ? '' : "<script type=\"text/javascript\">#{cdata}</script>"
  
    #sub styles into the header
    html_content = giri_doc.to_s.gsub("</head>", "#{inline_style_head}#{style_head}</head>")
    
    #sub in the footer
    static_footer = "#{inline_cdata_head}#{script_head}#{inline_script_head}"
    # write_static_tmpl "static_footer.php", static_footer if is_first_page
    html_content = html_content.gsub("</body>", "#{static_footer}</body>")
    
    #other random substitutions
    do_html_gsubs(html_content)
  end
  
  def do_html_gsubs html
    @html_subs.each do |key, value|
      key, value = interpolate_gsub_strs(key), interpolate_gsub_strs(value)
      html.gsub!(key, value)
    end
    html.gsub(/\n\s+\n/, "\n") #remove white space from removed lines
  end
  
  #replace strings like #base# with the value of @base for html gsub replacement strings
  def interpolate_gsub_strs str_to_interpolate
    str_to_interpolate.gsub('#base#',@base.chomp('/')).gsub('#cdn_base#',@cdn_base.chomp('/')).gsub('#link_base#',@link_base.chomp('/'))
  end
  
  def fix_element_paths page, selectors, base = @base, rewrite_base = @cdn_base
   #chomping necessary because could point to root with no /
   base = base.chomp '/'
   rewrite_base = rewrite_base.chomp '/'
   page.css(selectors).each do |i| 
     i.attributes.each do |a| # a -> ["src", #<Nokogiri::XML::Attr:0x3fc40e42dfd0 name="src" value="ben.png">] 
       name = a[0]
       scheme = URI.parse(rewrite_base).scheme
       base_host = URLUtil::base_host(base)
       rewrite_host = URLUtil::base_host(rewrite_base)
       absolute = URLUtil::make_absolute(i[name], base, scheme)
       gsubed = absolute.gsub(base, rewrite_base).gsub(base_host, rewrite_host)
       i[name] = gsubed unless name.downcase == 'class' || name.downcase == 'id'
     end
   end
  end
  
  #remove junk elements
  def remove_element_paths page, selectors
     page.css(selectors).each do |i| 
       i.remove
     end
  end
  

  def get_head_node giri_doc
    return '' if giri_doc.nil? || giri_doc.to_s.size == 0 #handle nil page
    head_elems = giri_doc.css('head')
    # binding.pry
    html = head_elems.empty? || head_elems.size == 0 ? '' : head_elems.first.inner_html
  end

  def write_changed_images
    #only push new images from staging
    pwd_path = %x{pwd}
    vhost_path = "/var/www/vhosts/staging.discoverhawaiitours.com/httpdocs"
    timestamp = Time.now.strftime("%Y-%m-%d-%H%M%S")
    if pwd_path.include?(vhost_path)
      add_images_cmd = "cd wp-content/uploads;"
#      add_images_cmd += "find . -iname *.jpg -exec jpegoptim -p -m60 --strip-all {};find . -name *.png | xargs optipng -nc -nb -o7 -full;"
      add_images_cmd += "git add *;git commit -a -m \"adding new images for mirror deployment #{timestamp}\" >> #{vhost_path}/deploy_data/changed_images.txt;"
      add_images_cmd += "git pull origin master;git push origin master;"
      puts add_images_cmd
      output = %x{#{add_images_cmd}}
      puts output
      
      if File.exists? "deploy_data/changed_images.txt"
        lines = File.open("deploy_data/changed_images.txt").readlines
        puts "\nWriting changed images:"
        lines.each do |line|
          line.split(' ').each do |path|
            # begin
               write_options = {:force_msg => true}
               path = 'wp-content/uploads/' + path
               @writer.write_file_to_s3 path.gsub("\n",""), write_options if FileUtil.is_image?(path) && File.exists?(path)
            # rescue
               # puts "file #{path} could not be opened to write to cdn"
            # end
          end
        end
      else
        puts "No changed image file to read."
      end
    end
  end
end
deploy_process = nil
time = Benchmark.realtime { deploy_process = Deploy.new }
puts "\nFinished. Created #{deploy_process.page_counter} pages in #{(time/60).round(2)} minutes.\n"
