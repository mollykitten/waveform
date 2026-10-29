#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "app_links/app_links_plugin_c_api.h"

#include "flutter_window.h"
#include "utils.h"

// Finds the running main window and hands it the waveform:// link. The title
// changes while a track plays ("Waveform · artist — title"), so match by
// prefix instead of the exact title.
static bool SendAppLinkToInstance() {
  HWND hwnd = nullptr;
  while ((hwnd = ::FindWindowEx(nullptr, hwnd,
                                L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr)) !=
         nullptr) {
    wchar_t title[256] = {};
    ::GetWindowTextW(hwnd, title, 256);
    if (wcsncmp(title, L"Waveform", 8) == 0) {
      break;
    }
  }
  if (hwnd == nullptr) {
    return false;
  }

  SendAppLink(hwnd);

  WINDOWPLACEMENT place = {sizeof(WINDOWPLACEMENT)};
  ::GetWindowPlacement(hwnd, &place);
  ::ShowWindow(hwnd, place.showCmd == SW_SHOWMAXIMIZED ? SW_SHOWMAXIMIZED
                                                       : SW_RESTORE);
  ::SetForegroundWindow(hwnd);
  return true;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // A second launch (e.g. a waveform:// link) forwards its link to the running
  // instance and exits.
  if (SendAppLinkToInstance()) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Waveform", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
