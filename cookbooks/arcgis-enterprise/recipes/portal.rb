#
# Cookbook Name:: arcgis-enterprise
# Recipe:: portal
#
# Copyright 2018-2025 Esri
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
#

# Fail fast if placeholders are used as values of sensitive attributes
Utils.check_sensitive_value('arcgis.portal.admin_email', node['arcgis']['portal']['admin_email'])
Utils.check_sensitive_value('arcgis.portal.admin_password', node['arcgis']['portal']['admin_password'])
Utils.check_sensitive_value('arcgis.portal.security_question_answer', node['arcgis']['portal']['security_question_answer'])

include_recipe 'arcgis-enterprise::install_portal'

# Set hostname in hostname.properties file.
template ::File.join(node['arcgis']['portal']['install_dir'],
                     node['arcgis']['portal']['install_subdir'],
                     'framework', 'etc', 'hostname.properties') do
  source 'hostname.properties.erb'
  owner node['arcgis']['run_as_user']
  group node['arcgis']['run_as_group']
  variables ( {:hostname => node['arcgis']['portal']['hostname']} )
  notifies :stop, 'arcgis_enterprise_portal[Stop Portal for ArcGIS]', :immediately
  not_if { node['arcgis']['portal']['hostname'].empty? }
end

# Set hostidentifier and preferredidentifier in hostidentifier.properties file.
arcgis_enterprise_portal 'Configure hostidentifier.properties' do
  action :configure_hostidentifiers_properties
end

arcgis_enterprise_portal 'Stop Portal for ArcGIS' do
  tomcat_java_opts node['arcgis']['portal']['tomcat_java_opts']
  action :nothing
end

arcgis_enterprise_portal 'Start Portal for ArcGIS' do
  tomcat_java_opts node['arcgis']['portal']['tomcat_java_opts']
  action :start
end

arcgis_enterprise_portal 'Validate Portal for ArcGIS Authorization File' do
  authorization_file node['arcgis']['portal']['authorization_file']
  portal_url node['arcgis']['portal']['url']
  username node['arcgis']['portal']['admin_username']
  password node['arcgis']['portal']['admin_password']
  action :authorize
end

# Create Site
arcgis_enterprise_portal 'Create Portal Site' do
  portal_url node['arcgis']['portal']['url']
  user_license_type_id node['arcgis']['portal']['user_license_type_id']
  authorization_file node['arcgis']['portal']['authorization_file']
  username node['arcgis']['portal']['admin_username']
  password node['arcgis']['portal']['admin_password']
  full_name node['arcgis']['portal']['admin_full_name']
  email node['arcgis']['portal']['admin_email']
  description node['arcgis']['portal']['admin_description']
  security_question_index node['arcgis']['portal']['security_question_index']
  security_question_answer node['arcgis']['portal']['security_question_answer']
  install_dir node['arcgis']['portal']['install_dir']
  content_store_type node['arcgis']['portal']['content_store_type']
  content_store_provider node['arcgis']['portal']['content_store_provider']
  content_store_connection_string node['arcgis']['portal']['content_store_connection_string']
  object_store node['arcgis']['portal']['object_store']
  upgrade_backup node['arcgis']['portal']['upgrade_backup']
  upgrade_rollback node['arcgis']['portal']['upgrade_rollback']
  enable_debug node['arcgis']['portal']['enable_debug']
  action :create_site
end

directory node['arcgis']['portal']['log_dir'] do
  owner node['arcgis']['run_as_user']
  mode '0700' if node['platform'] != 'windows'
  recursive true
  action :create
end

arcgis_enterprise_portal 'Set Portal System Properties' do
  portal_url node['arcgis']['portal']['url']
  username node['arcgis']['portal']['admin_username']
  password node['arcgis']['portal']['admin_password']
  log_level node['arcgis']['portal']['log_level']
  log_dir node['arcgis']['portal']['log_dir']
  max_log_file_age node['arcgis']['portal']['max_log_file_age']
  system_properties node['arcgis']['portal']['system_properties']
  retries 5
  retry_delay 60
  action :set_system_properties
end

arcgis_enterprise_portal 'Import Root Certificates' do
  portal_url node['arcgis']['portal']['url']
  username node['arcgis']['portal']['admin_username']
  password node['arcgis']['portal']['admin_password']
  root_cert node['arcgis']['portal']['root_cert']
  root_cert_alias node['arcgis']['portal']['root_cert_alias']
  not_if { node['arcgis']['portal']['root_cert'].empty? ||
           node['arcgis']['portal']['root_cert_alias'].empty?}
  retries 5
  retry_delay 30
  action :import_root_cert
end

arcgis_enterprise_portal 'Configure HTTPS' do
  portal_url node['arcgis']['portal']['url']
  username node['arcgis']['portal']['admin_username']
  password node['arcgis']['portal']['admin_password']
  keystore_file node['arcgis']['portal']['keystore_file']
  keystore_password node['arcgis']['portal']['keystore_password']
  cert_alias node['arcgis']['portal']['cert_alias']
  import_certificate_chain node['arcgis']['portal']['import_certificate_chain']
  hsts_enabled node['arcgis']['portal']['hsts_enabled']
  retries 5
  retry_delay 30
  action :configure_https
end

arcgis_enterprise_portal 'Update Organization Information' do
  portal_url node['arcgis']['portal']['url']
  username node['arcgis']['portal']['admin_username']
  password node['arcgis']['portal']['admin_password']
  organization node['arcgis']['portal']['organization']
  retries 5
  retry_delay 30
  action :update_org_info
end

arcgis_enterprise_portal 'Update Organization Settings' do
  portal_url node['arcgis']['portal']['url']
  username node['arcgis']['portal']['admin_username']
  password node['arcgis']['portal']['admin_password']
  org_settings node['arcgis']['portal']['settings']
  retries 5
  retry_delay 30
  action :update_org_settings
end

arcgis_enterprise_portal "Update Email Settings" do
  portal_url node['arcgis']['portal']['url']
  username node['arcgis']['portal']['admin_username']
  password node['arcgis']['portal']['admin_password']
  email_settings node['arcgis']['portal']['email_settings']
  retries 5
  retry_delay 30
  action :update_email_settings
end
