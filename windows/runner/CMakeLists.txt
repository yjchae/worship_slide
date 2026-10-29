cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "media_layer.cpp"
  "ocr_channel.cpp"
  "presentation_channel.cpp"
  "singer_window.cpp"
  "speech_channel.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# 발표창의 이미지 슬라이드(GDI+) 렌더링용
target_link_libraries(${BINARY_NAME} PRIVATE "gdiplus.lib")
# 원본 PPT 열기(ShellExecuteW)
target_link_libraries(${BINARY_NAME} PRIVATE "shell32.lib")
# 악보 가사 OCR(Windows.Media.Ocr, C++/WinRT)
target_link_libraries(${BINARY_NAME} PRIVATE "windowsapp.lib")
# 발표 창 미디어 레이어(동영상·음악·유튜브). NuGet 패키지(zip)를 받아 헤더와 정적 로더만 쓴다 —
# 정적 로더라 WebView2Loader.dll 을 같이 배포할 필요가 없다. 런타임은 Windows 10/11 기본 탑재.
include(FetchContent)
FetchContent_Declare(webview2
  URL https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.3967.48/microsoft.web.webview2.1.0.3967.48.nupkg
  URL_HASH SHA256=c66357ac7f324ec9bcafe5241706a023b4122d8c22300c31de4b0eb220db689e
  DOWNLOAD_NAME webview2.zip
)
FetchContent_MakeAvailable(webview2)
target_include_directories(${BINARY_NAME} PRIVATE "${webview2_SOURCE_DIR}/build/native/include")
target_link_libraries(${BINARY_NAME} PRIVATE "${webview2_SOURCE_DIR}/build/native/x64/WebView2LoaderStatic.lib" "version.lib")
# C++/WinRT 는 C++17 이면 <experimental/coroutine> 을 끌어오는데, 최신 MSVC 는 이를 에러(STL1011)로 막는다.
target_compile_features(${BINARY_NAME} PRIVATE cxx_std_20)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
