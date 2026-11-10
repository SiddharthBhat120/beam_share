#include "beam_platform.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <random>
#include <string>

// C++/WinRT headers (ship with the Windows SDK).
#pragma warning(push, 0)
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Devices.WiFiDirect.h>
#include <winrt/Windows.Security.Credentials.h>
#pragma warning(pop)

namespace wfd = winrt::Windows::Devices::WiFiDirect;

struct BeamPlatform::Impl {
  wfd::WiFiDirectAdvertisementPublisher publisher{nullptr};
  wfd::WiFiDirectConnectionListener listener{nullptr};
  winrt::event_token request_token{};
};

namespace {

std::string RandomPassphrase() {
  static const char kChars[] = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  std::random_device rd;
  std::uniform_int_distribution<int> dist(0, static_cast<int>(sizeof(kChars) - 2));
  std::string out;
  for (int i = 0; i < 12; i++) out.push_back(kChars[dist(rd)]);
  return out;
}

std::string SafeName(const std::string& name) {
  std::string out;
  for (char c : name) {
    if (((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) && out.size() < 12) {
      out.push_back(c);
    }
  }
  return out.empty() ? "PC" : out;
}

const std::string* GetString(const flutter::EncodableValue* args, const char* key) {
  if (!args) return nullptr;
  const auto* map = std::get_if<flutter::EncodableMap>(args);
  if (!map) return nullptr;
  auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) return nullptr;
  return std::get_if<std::string>(&it->second);
}

bool GetBool(const flutter::EncodableValue* args, const char* key) {
  if (!args) return false;
  const auto* map = std::get_if<flutter::EncodableMap>(args);
  if (!map) return false;
  auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) return false;
  const auto* b = std::get_if<bool>(&it->second);
  return b && *b;
}

}  // namespace

BeamPlatform::BeamPlatform(flutter::BinaryMessenger* messenger) : impl_(std::make_unique<Impl>()) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "beam/platform", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) { HandleCall(call, std::move(result)); });
}

BeamPlatform::~BeamPlatform() {
  try {
    if (impl_->publisher) impl_->publisher.Stop();
  } catch (...) {
  }
  SetThreadExecutionState(ES_CONTINUOUS);
}

void BeamPlatform::HandleCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  if (method == "startHotspot") {
    const std::string* name = GetString(call.arguments(), "name");
    const std::string ssid = "DIRECT-bs-" + SafeName(name ? *name : "PC");
    const std::string pass = RandomPassphrase();
    try {
      if (impl_->publisher) {
        impl_->publisher.Stop();
        impl_->publisher = nullptr;
      }
      wfd::WiFiDirectAdvertisementPublisher publisher;
      auto adv = publisher.Advertisement();
      adv.IsAutonomousGroupOwnerEnabled(true);
      auto legacy = adv.LegacySettings();
      legacy.IsEnabled(true);
      legacy.Ssid(winrt::to_hstring(ssid));
      winrt::Windows::Security::Credentials::PasswordCredential cred;
      cred.Password(winrt::to_hstring(pass));
      legacy.Passphrase(cred);

      // Accept Wi-Fi Direct connection requests (legacy clients don't need
      // this, but some Windows/Android peers use real Wi-Fi Direct).
      impl_->listener = wfd::WiFiDirectConnectionListener();
      impl_->request_token = impl_->listener.ConnectionRequested(
          [](const wfd::WiFiDirectConnectionListener&, const wfd::WiFiDirectConnectionRequestedEventArgs& args) {
            try {
              auto request = args.GetConnectionRequest();
              request.Close();
            } catch (...) {
            }
          });

      publisher.Start();
      // Wait up to ~2 s for the soft-AP to come up.
      for (int i = 0; i < 20; i++) {
        auto status = publisher.Status();
        if (status == wfd::WiFiDirectAdvertisementPublisherStatus::Started) break;
        if (status == wfd::WiFiDirectAdvertisementPublisherStatus::Aborted) {
          result->Error("hotspot_failed", "Wi-Fi Direct is not available on this PC (no compatible Wi-Fi adapter?)");
          return;
        }
        Sleep(100);
      }
      impl_->publisher = publisher;
      flutter::EncodableMap out;
      out[flutter::EncodableValue("ssid")] = flutter::EncodableValue(ssid);
      out[flutter::EncodableValue("passphrase")] = flutter::EncodableValue(pass);
      out[flutter::EncodableValue("mode")] = flutter::EncodableValue("wifi-direct");
      result->Success(flutter::EncodableValue(out));
    } catch (const winrt::hresult_error& e) {
      result->Error("hotspot_failed", winrt::to_string(e.message()));
    } catch (...) {
      result->Error("hotspot_failed", "unknown error");
    }
    return;
  }

  if (method == "stopHotspot") {
    try {
      if (impl_->publisher) impl_->publisher.Stop();
    } catch (...) {
    }
    impl_->publisher = nullptr;
    impl_->listener = nullptr;
    result->Success();
    return;
  }

  if (method == "keepScreenOn") {
    if (GetBool(call.arguments(), "on")) {
      SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);
    } else {
      SetThreadExecutionState(ES_CONTINUOUS);
    }
    result->Success();
    return;
  }

  result->NotImplemented();
}
