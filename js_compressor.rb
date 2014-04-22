#this example demonstrates how to curl and compress javascript automatically for pages

class JSCompressor
  DEBUG = false
  attr_accessor :writer, :base, :cdn_base, :link_base, :styles, :exclude_scripts, :include_scripts
  def initialize writer, base, cdn_base, link_base, include_scripts, exclude_scripts
    @base, @cdn_base, @link_base = base, cdn_base, link_base
    @writer = writer
    @external_scripts = []
    @include_scripts = include_scripts
    @exclude_scripts = exclude_scripts
  end
  
  #extract src tags from page and add to collection
  def get_srcs page, url
    scripts = {:external => [], :internal => '', :cdata => ''}
    page.css("script").each do |s|
      next if s['data-cdata']
      if s['src']
        external_script = is_external(s['src']) ? s["src"] : s["src"].gsub(@base,'').rchomp('/')
        scripts[:external] << external_script
      elsif s.text.to_s.length != 0
        file_name = 'static/js/inline_js.js'
        inline_script = s.text.gsub(URLUtil::base_host(@base), URLUtil::base_host(@link_base))
        dir = File.dirname(file_name)
        FileUtils.mkdir_p(dir) unless File.directory?(dir)
        open(file_name, 'a') { |f|
          f.puts "/*#{url}*/\n"
          f.puts s.text + "\n\n"
        }
        if inline_script.include? 'CDATA'
          scripts[:cdata] << inline_script
        else
          scripts[:internal] << inline_script
        end
      end
      s.remove
    end
    @external_scripts << scripts[:external]
    scripts
  end
  
  #whether url is external or local to the site
  def is_external script_url
    (script_url.start_with?('//') || script_url.start_with?('http')) && !script_url.include?(@base)
  end
  
  #make the url external by fully qualifying it
  def make_external script_url
    if script_url.start_with?('//')
      script_url = 'http:' + script_url
    elsif !script_url.start_with?('http')
      script_url = @base + script_url
    end
    script_url
  end
  
  #unique all script tags -internal and external
  def uniq_externals
     @external_scripts << @include_scripts
     @external_scripts = @external_scripts.flatten.compact
     @external_scripts = @external_scripts.collect { |s| s.split('?').first }
     @external_scripts.uniq!
  end
  
  #compress the javascript
  def compress
     uniq_externals
     all_scripts, jquery_scripts = "", ""
     jquery_urls, all_urls = [], []
     cpiler = Closure::Compiler.new
     cpressor = YUI::JavaScriptCompressor.new
     
     @external_scripts.each do |s|
         if !@exclude_scripts.include?(s.split('?')[0]) && !s.include?('cache/widgetkit')
           url =  make_external(s)
           body = URLUtil::read_body url
           unless body.to_s.size == 0
             if url.include?('jquery')
               jquery_scripts << "\n/*#{url}*/\n#{body}"
               jquery_urls << url
             else
               begin
                 closured = body #cpiler.compile(body)
                 all_scripts << "\n/*#{url}*/\n#{closured}" unless closured.empty?
                 all_urls << url
               rescue Closure::Error
                 puts "\nProblem closure compiling external js #{url}"
               end
             end
           end
         end
     end

     compressed_scripts = jquery_scripts #for jquery urls to the top of the script block to allow library use
     
     #capture errors with compressing due to bad syntax
     begin
       compressed_scripts << cpressor.compress(all_scripts.encode('UTF-8', {:invalid => :replace, :undef => :replace, :replace => '?'}))
     rescue YUI::Compressor::RuntimeError
       puts "\nProblem compressing all external js with these urls #{all_urls.join(',')}"
       compressed_scripts << all_scripts
     end
     
     #write gzipped and non compressed versions as well 
     @writer.write_file 'static/js/app.js.html', logify_urls(log_urls)
     @writer.write_file 'static/js/app.js', jquery_scripts + all_scripts
     @writer.write_file 'static/js/app.min.js', compressed_scripts, false

     
     %x(gzip -f9 static/js/app.min.js;mv -f static/js/app.min.js.gz static/js/app.min.js)
     @writer.write_file_to_s3 'static/js/app.min.js' unless DEBUG_DEPLOY
   end
end