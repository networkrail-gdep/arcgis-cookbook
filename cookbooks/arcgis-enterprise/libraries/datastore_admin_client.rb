#
# Copyright 2025 Esri
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'net/http'
require 'uri'
require 'json'

#
# ArcGIS helper classes
#
module ArcGIS
  #
  # Client class for ArcGIS Data Store administrative directory API.
  #
  class DataStoreAdminClient
    MAX_RETRIES = 300
    SLEEP_TIME = 10.0
  
    @datastore_admin_url = nil
  
    def initialize(datastore_admin_url = "https://localhost:2443/arcgis/datastoreadmin")
      @datastore_admin_url = datastore_admin_url
    end

    def wait_until_available(redirects = 0)
      Utils.wait_until_url_available(@datastore_admin_url + '/?f=json', redirects)
    end

    def info
      uri = URI.parse(@datastore_admin_url + '/configure')

      uri.query = URI.encode_www_form('f' => 'json')

      request = Net::HTTP::Get.new(uri.request_uri)
      request.add_field('Referer', 'referer')

      response = send_request(request, @datastore_admin_url)

      validate_response(response)

      JSON.parse(response.body)            
    end

    private

    def send_request(request, url, sensitive = false)
      uri = URI.parse(url)

      http = Net::HTTP.new(uri.host, uri.port)
      http.read_timeout = 3600

      if uri.scheme == 'https'
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end

      Chef::Log.debug("Request: #{request.method} #{uri.scheme}://#{uri.host}:#{uri.port}#{request.path}")

      if sensitive
        Chef::Log.debug("Request body was not logged because it contains sensitive information.") 
      else
        Chef::Log.debug(request.body) unless request.body.nil?
      end

      response = http.request(request)

      if response.code.to_i == 301
        Chef::Log.debug("Moved to: #{response.header['location']}")

        uri = URI.parse(response.header['location'])

        http = Net::HTTP.new(uri.host, uri.port)
        http.read_timeout = 3600

        if uri.scheme == 'https'
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end

        if request.method == 'POST'
          body = request.body
          request = Net::HTTP::Post.new(URI.parse(
            response.header['location']).request_uri)
          request.body = (body)
        else
          request = Net::HTTP::Get.new(URI.parse(
            response.header['location']).request_uri)
        end

        request.add_field('Referer', 'referer')

        response = http.request(request)
      end

      Chef::Log.debug("Response: #{response.code} #{response.body}")

      response
    end

    def validate_response(response)
      if response.code.to_i == 301
        raise 'Moved permanently to ' + response.header['location']
      elsif response.code.to_i > 300
        raise response.message
      else
        if response.code.to_i == 200
          error_info = JSON.parse(response.body)
          if error_info['status'] == 'error'
            raise error_info['messages'].join(' ')
          end
        end
      end
    end
  end
end
