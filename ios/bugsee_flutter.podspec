Pod::Spec.new do |s|
  s.name             = 'bugsee_flutter'
  s.version          = '99.99.99'
  s.summary          = 'Bugsee plugin for Flutter'
  s.description      = <<-DESC
Bugsee Flutter SDK is a powerful bug and crash reporting tool for
Flutter applications. It provides real-time insights into your
app's performance and user experience by capturing detailed
information about crashes, network requests, user interactions,
and more. With Bugsee, you can dramatically reduce the time needed
to identify, reproduce, and fix issues in your Flutter applications.
                       DESC
  s.license          = { :type => 'MIT' }
  s.homepage         = 'https://www.bugsee.com'
  s.author           = { 'Bugsee' => 'support@bugsee.com' }
  s.source           = { :path => '.' }
  s.source_files = 'bugsee_flutter/Sources/bugsee_flutter/**/*.{h,m,swift}'
  s.public_header_files = 'bugsee_flutter/Sources/bugsee_flutter/include/**/*.h'
  s.resource_bundles = {'bugsee_flutter_privacy' => ['bugsee_flutter/Sources/bugsee_flutter/PrivacyInfo.xcprivacy']}
  s.dependency 'Flutter'
  s.dependency 'Bugsee'
  s.static_framework = true

  s.pod_target_xcconfig = { 'OTHER_LDFLAGS' => '"$(inherited)" "-framework" "Flutter" "-framework" "Bugsee"' }
  s.ios.deployment_target = '11.0'
end

