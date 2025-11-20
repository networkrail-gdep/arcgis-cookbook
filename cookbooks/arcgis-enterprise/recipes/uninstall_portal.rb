#
# Cookbook Name:: arcgis-enterprise
# Recipe:: uninstall_portal
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
#

arcgis_enterprise_webstyles 'Uninstall ArcGIS Web Styles' do
  install_dir node['arcgis']['portal']['install_dir']
  product_code node['arcgis']['webstyles']['product_code']
  run_as_user node['arcgis']['run_as_user']
  if node['platform'] == 'windows'
    only_if { Utils.product_installed?(node['arcgis']['webstyles']['product_code']) }
  else
    only_if { EsriProperties.product_installed?(node['arcgis']['run_as_user'],
                                                node['hostname'],
                                                node['arcgis']['version'],
                                                :ArcGISPortal_WebStyles) }
  end
  action :uninstall
end

arcgis_enterprise_portal 'Uninstall Portal for ArcGIS' do
  install_dir node['arcgis']['portal']['install_dir']
  product_code node['arcgis']['portal']['product_code']
  run_as_user node['arcgis']['run_as_user']
  if node['platform'] == 'windows'
    only_if { Utils.product_installed?(node['arcgis']['portal']['product_code']) }
  else
    only_if { EsriProperties.product_installed?(node['arcgis']['run_as_user'],
                                                node['hostname'],
                                                node['arcgis']['version'],
                                                :ArcGISPortal) }
  end
  action :uninstall
end
