require 'xcodeproj'
require 'fileutils'
root = File.expand_path('../ios', __dir__)
project = Xcodeproj::Project.new(File.join(root, 'Collector.xcodeproj'))
target = project.new_target(:application, 'Collector', :ios, '16.0')
group = project.main_group.new_group('Collector', 'Collector')
Dir.glob(File.join(root, 'Collector', '*.swift')).sort.each do |path|
  ref = group.new_file(File.basename(path))
  target.source_build_phase.add_file_reference(ref)
end
asset = group.new_file('Assets/yolo11n-seg-trained-v1.tflite')
target.resources_build_phase.add_file_reference(asset)
target.build_configurations.each do |c|
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.eachpathhealth.arcollector'
  c.build_settings['PRODUCT_NAME'] = 'Collector'
  c.build_settings['SWIFT_VERSION'] = '5.0'
  c.build_settings['DEVELOPMENT_TEAM'] = 'KY3Z9XN2R7'
  c.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  c.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  c.build_settings['INFOPLIST_KEY_CFBundleDisplayName'] = 'EachPath Collector'
  c.build_settings['INFOPLIST_KEY_NSCameraUsageDescription'] = 'Capture test-kit photographs for a reviewed training dataset. Photos are uploaded to the collector database.'
  c.build_settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  c.build_settings['INFOPLIST_KEY_UIApplicationSceneManifest_Generation'] = 'YES'
  c.build_settings['INFOPLIST_KEY_UISupportedInterfaceOrientations'] = 'UIInterfaceOrientationPortrait'
  c.build_settings['TARGETED_DEVICE_FAMILY'] = '1'
end
tests = project.new_target(:unit_test_bundle, 'CollectorTests', :ios, '16.0')
tests.add_dependency(target)
tg = project.main_group.new_group('CollectorTests', 'CollectorTests')
Dir.glob(File.join(root, 'CollectorTests', '*.swift')).sort.each do |p|
  tests.source_build_phase.add_file_reference(tg.new_file(File.basename(p)))
end
tests.build_configurations.each do |c|
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.eachpathhealth.arcollector.tests'
  c.build_settings['SWIFT_VERSION'] = '5.0'
  c.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  c.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Collector.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Collector'
  c.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.add_test_target(tests)
scheme.set_launch_target(target)
scheme.save_as(File.join(root, 'Collector.xcodeproj'), 'Collector', true)
