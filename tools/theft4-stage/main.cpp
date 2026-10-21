#include "gta4_installer.h"
#include <rex/logging.h>
#include <chrono>
#include <cstdio>
#include <exception>
#include <thread>

int main(int argc, char** argv) {
  if (argc != 4) {
    std::fprintf(stderr, "Usage: theft4_stage <base ISO> <TU8 package> <NEW destination>\n");
    return 2;
  }
  rex::LogConfig log_config;
  log_config.log_to_console = true;
  log_config.default_level = spdlog::level::trace;
  rex::InitLogging(log_config);
  int status = 1;
  try {
    auto destination = std::filesystem::absolute(argv[3]).lexically_normal();
    if (destination == destination.root_path() || !std::filesystem::create_directory(destination))
      throw std::runtime_error("Destination must be a new directory with an existing parent");
    gta4::install::Progress progress;
    std::jthread reporter([&](std::stop_token stop) {
      while (!stop.stop_requested()) {
        std::printf("Staging: %llu / %llu bytes\n", (unsigned long long)progress.copied_bytes.load(), (unsigned long long)progress.total_bytes.load());
        std::fflush(stdout);
        for (int i = 0; i < 10 && !stop.stop_requested(); ++i)
          std::this_thread::sleep_for(std::chrono::milliseconds(500));
      }
    });
    const gta4::install::Selection selection{argv[1], argv[2], {}};
    auto result = gta4::install::Install(selection, destination, progress);
    if (result.success) result = gta4::install::VerifyInstall(destination / "game", destination / "dlc");
    reporter.request_stop();
    status = result.success ? 0 : 1;
    const std::string message = result.success ? destination.string() : result.error;
    std::printf("Staging %s: %s\n", result.success ? "VERIFIED" : "FAILED", message.c_str());
  } catch (const std::exception& error) {
    std::fprintf(stderr, "Staging failed: %s\n", error.what());
  }
  rex::ShutdownLogging();
  return status;
}
