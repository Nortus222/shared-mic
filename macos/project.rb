#!/usr/bin/env ruby
# Deterministic generator for macos/SharedMic.xcodeproj.
#
# The .xcodeproj is a build artifact that happens to be committed; THIS file is
# the source of truth. Re-run it after adding or removing any .swift file:
#
#   ruby macos/project.rb
#
# Requires the `xcodeproj` gem (already installed on this machine: 1.27.0).

require 'xcodeproj'
require 'fileutils'

ROOT = File.dirname(File.expand_path(__FILE__))
PROJECT_PATH = File.join(ROOT, 'SharedMic.xcodeproj')
DEPLOYMENT_TARGET = '14.4'
SWIFT_VERSION = '5.0'
MARKETING_VERSION = '0.1.0'
CURRENT_PROJECT_VERSION = '1'

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)

project.build_configurations.each do |config|
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  config.build_settings['SWIFT_VERSION'] = SWIFT_VERSION
  config.build_settings['ALWAYS_SEARCH_USER_PATHS'] = 'NO'
  config.build_settings['CLANG_ENABLE_OBJC_ARC'] = 'YES'
  config.build_settings['SDKROOT'] = 'macosx'
end

app = project.new_target(:application, 'SharedMic', :osx, DEPLOYMENT_TARGET)
tests = project.new_target(:unit_test_bundle, 'SharedMicTests', :osx, DEPLOYMENT_TARGET)

app_group = project.new_group('SharedMic', 'SharedMic')
test_group = project.new_group('SharedMicTests', 'SharedMicTests')

def add_swift_sources(group, target, directory)
  Dir.glob(File.join(directory, '**', '*.swift')).sort.each do |file|
    relative = file.sub(directory + '/', '')
    reference = group.new_reference(relative)
    target.add_file_references([reference])
  end
end

add_swift_sources(app_group, app, File.join(ROOT, 'SharedMic'))
add_swift_sources(test_group, tests, File.join(ROOT, 'SharedMicTests'))

app.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_NAME'] = 'SharedMic'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.sharedmic.SharedMic'
  settings['INFOPLIST_FILE'] = 'SharedMic/Info.plist'
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['MARKETING_VERSION'] = MARKETING_VERSION
  settings['CURRENT_PROJECT_VERSION'] = CURRENT_PROJECT_VERSION
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CODE_SIGN_IDENTITY'] = '-'
  settings['CODE_SIGN_ENTITLEMENTS'] = 'SharedMic/SharedMic.entitlements'
  settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
  settings['COMBINE_HIDPI_IMAGES'] = 'YES'
  settings['SWIFT_VERSION'] = SWIFT_VERSION
  settings['MACOSX_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
end

tests.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_NAME'] = 'SharedMicTests'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.sharedmic.SharedMicTests'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CODE_SIGN_IDENTITY'] = '-'
  settings['SWIFT_VERSION'] = SWIFT_VERSION
  settings['MACOSX_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/SharedMic.app/Contents/MacOS/SharedMic'
  settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end

tests.add_dependency(app)
project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.save_as(PROJECT_PATH, 'SharedMic', true)

puts "generated #{PROJECT_PATH}"
