# -*- coding: utf-8 -*-

AfterStep do |scenario|
  unless $html_validator
    FileUtils.rm_rf W3cHtmlValidator::BASE_TMP_DIR
    FileUtils.mkdir_p W3cHtmlValidator::BASE_TMP_DIR
    FileUtils.touch File.join(W3cHtmlValidator::BASE_TMP_DIR, "dummy.txt")
    $html_validator = W3cHtmlValidator.new
  end
  $html_validator.validate page.html, current_url
end

class HtmlValidator
  BASE_TMP_DIR = Rails.root.join "tmp", "html_validator"

  def initialize
    @count = 0
  end

  def tmp_dir
    File.join(BASE_TMP_DIR, object_id.to_s(16), @count.to_s)
  end
  
  def validate(html, path)
    return if [nil, "", "about:blank"].include? path

    result = get_validation_result html
    return if result["errors"].empty?

    @count += 1
    FileUtils.mkdir_p tmp_dir
    html_file = File.join(tmp_dir, "input.html")
    
    message = "URL: #{path}\n"
    result["errors"].each do |error|
      message += "  #{error["type"]}: #{error["lastLine"]}:#{error["lastColumn"]}:#{error["message"]}\n"
    end

    message += "See `#{tmp_dir}' files for more information.\n"
    
    File.binwrite html_file, html
    File.binwrite File.join(tmp_dir, "raw_result.txt"), result["raw_result"]
    File.binwrite File.join(tmp_dir, "error_message.txt"), message

    fail message
  end
end

class W3cHtmlValidator < HtmlValidator
  def get_validation_result(html)
    uri = URI.parse('http://10.1.10.161:15000/w3c-validator/check')
    WebMock.disable_net_connect!(:allow => "#{uri.host}:#{uri.port}") if defined?(WebMock) # ...
    response = Net::HTTP.start(uri.host, uri.port) do |http|
      request = Net::HTTP::Post.new(uri.path)
      boundary = "boundary#{rand(1000 * 1000 * 1000)}"
      request.set_content_type("multipart/form-data; boundary=#{boundary}")
      request_body = ""
      add_boundary = ->(disposition_name, data, disposition_filename = nil, type = nil) do
        request_body += "--#{boundary}\r\n"
        request_body += "Content-Disposition: form-data; name=\"#{disposition_name}\""
        if disposition_filename
          request_body += "; filename=\"#{disposition_filename}\""
        end
        request_body += "\r\n"
        if type
          request_body += "Content-Type: #{type}\r\n"
        end
        request_body += "\r\n"
        request_body += "#{data}\r\n"
      end
      
      add_boundary.call "uploaded_file", html, "test.html", "text/html"
      add_boundary.call "charset", "utf-8"
      add_boundary.call "doctype", "inline"
      add_boundary.call "output", "json"
      add_boundary.call "group", "0"
      add_boundary.call "user-agent", "W3C_Validator/1.2"
      
      request_body += "--#{boundary}--\r\n"
      request.body = request_body
      http.request request
    end
    response.value # raise exception

    raw_result = response.body
    raw_result.force_encoding "".encoding
    unless raw_result.valid_encoding?
      return {
        "raw_result" => raw_result,
        "errors" => [{"message" => "Invalid response encoding"}]
      }
    end
    
    ignore_messages = []
    ignore_patterns = []

    unless html5? html
      ["OL", "UL"].each do |tag|
        ignore_messages << "end tag for \"#{tag}\" which is not finished"
      end
      ["PLACEHOLDER"].each do |attribute|
        ignore_messages << "there is no attribute \"#{attribute}\""
      end
      ignore_patterns << /^there is no attribute "DATA-[[:alnum:]-]+"$/
    end

    if defined?(MobileWeb::Application)
      ignore_messages << "the name and VI delimiter can be omitted from an attribute specification only if SHORTTAG YES is specified"
      ["meta", "br", "input", "hr"].each do |tag|
        ignore_messages << "end tag for \"#{tag}\" omitted, but OMITTAG NO was specified"
      end
      ["bordercolor"].each do |attribute|
        ignore_messages << "there is no attribute \"#{attribute}\""
      end
    end

    ignore_messages.each do |ignore_message|
      ignore_patterns << Regexp.new("^#{Regexp.quote(ignore_message)}$")
    end

    begin
      result = ActiveSupport::JSON.decode(raw_result)
    rescue MultiJson::DecodeError => e
      return {
        "raw_result" => raw_result,
        "errors" => [{"message" => e.inspect.force_encoding("".encoding)}] # why?
      }
    end

    errors = result["messages"].select { |message|
      message["type"] != "info" && !ignore_patterns.find { |pattern| message["message"] =~ pattern}
    }.map { |message|
      message.select { |key, _| ["lastLine", "lastColumn", "type", "message"].include? key}
    }
    
    {
      "raw_result" => raw_result,
      "errors" => errors,
    }
  end

  def html5?(html)
    html =~ /^\s*<!doctype\s+html\s*>/i
  end
end
