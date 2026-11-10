#ifndef RUNNER_BEAM_PLATFORM_H_
#define RUNNER_BEAM_PLATFORM_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Native Windows side of Beam Share ("beam/platform" channel).
//
//  * startHotspot / stopHotspot: an offline Wi-Fi network using the Wi-Fi
//    Direct "legacy" soft-AP. Phones join it like normal Wi-Fi (SSID +
//    password from the QR code). No router or internet needed.
//  * keepScreenOn: stops Windows from sleeping during a transfer.
//
// Joining another device's hotspot is done from Dart with "netsh".
class BeamPlatform {
 public:
  explicit BeamPlatform(flutter::BinaryMessenger* messenger);
  ~BeamPlatform();

 private:
  void HandleCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  // Implementation details (WinRT objects) live in the .cpp file.
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_BEAM_PLATFORM_H_
