#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Single-instance enforcement: a second launch (e.g. double-clicking the
  // desktop shortcut when the app is already open, which happens often on
  // a shared till PC) just brings the existing window to the front instead
  // of opening a duplicate app on top of it. The mutex is the source of
  // truth for "already running" -- released automatically on process exit,
  // no manual cleanup needed.
  ::CreateMutexW(nullptr, TRUE, L"ÇÇM-Barkod Okuyucu-SingleInstanceMutex");
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = ::FindWindowW(nullptr, L"ÇÇM-Barkod Okuyucu");
    if (existing != nullptr) {
      if (::IsIconic(existing)) {
        ::ShowWindow(existing, SW_RESTORE);
      }
      ::SetForegroundWindow(existing);
    }
    return EXIT_SUCCESS;
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
  // The window opens maximized (see Win32Window::Show); this is only the
  // "restored down" size the user gets when they un-maximize -- 1366x768,
  // the most common till/office screen, still roomy for the Urun Ara table.
  Win32Window::Size size(1366, 768);
  // This file is UTF-8; windows/CMakeLists.txt passes /utf-8 so MSVC reads
  // the literal below (and any other non-ASCII) correctly rather than as
  // the system codepage.
  if (!window.Create(L"ÇÇM-Barkod Okuyucu", origin, size)) {
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
