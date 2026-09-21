#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>

// Fixed storage, one serialized producer, one audio consumer. No locks or allocation.
namespace AeonDSP {
constexpr int filters = 20, channels = 8, lookahead = 128;
struct Configuration {
    int count = 0;
    double gain = 1;
    bool protect = false;
    double coefficients[filters][5] = {};
};
struct Bank {
    Configuration config;
    double state[channels][filters][2] = {};
    double sample(double x, int channel) {
        x *= config.gain;
        for (int i = 0; i < config.count; ++i) {
            const auto &c = config.coefficients[i]; auto &s = state[channel][i];
            double y = c[0] * x + s[0];
            s[0] = c[1] * x - c[3] * y + s[1];
            s[1] = c[2] * x - c[4] * y;
            x = y;
        }
        return std::isfinite(x) ? x : 0;
    }
};
class Kernel {
    Configuration mailbox[3];
    unsigned front = 0, back = 2; // consumer/producer owned respectively
    std::atomic<unsigned> middle{1}; // bit 2 means a newer snapshot is available
    Bank current, next;
    int transition = 0;
    bool started = false;
    double delayed[channels][lookahead + 1] = {};
    double peaks[lookahead + 1] = {};
    int cursor = 0;
    double limiterGain = 1;
    double release = 0.9996;
public:
    std::atomic<uint64_t> overloads{0};
    void prepare(double rate) { release = std::exp(-1 / (rate * 0.080)); }
    bool submit(const Configuration &config) {
        mailbox[back] = config;
        back = middle.exchange(back | 4, std::memory_order_acq_rel) & 3;
        return true;
    }
    void process(float **data, int count, int frames) {
        if (transition == 0 && (middle.load(std::memory_order_acquire) & 4)) {
            front = middle.exchange(front, std::memory_order_acq_rel) & 3;
            next = Bank{}; next.config = mailbox[front];
            if (!started) { current = next; } else { transition = 1536; }
        }
        started = true;
        constexpr double ceiling = 0.8912509381337456; // -1 dBFS sample peak, NOT dBTP
        for (int frame = 0; frame < frames; ++frame) {
            double peak = 0;
            for (int c = 0; c < count; ++c) {
                double x = std::isfinite(data[c][frame]) ? data[c][frame] : 0;
                double y = current.sample(x, c);
                if (transition > 0) {
                    double fresh = next.sample(x, c);
                    // First 512 frames warm the incoming state; then an equal-gain crossfade.
                    double mix = std::max(0.0, (1024.0 - transition) / 1024.0);
                    y += (fresh - y) * mix;
                }
                delayed[c][cursor] = y;
                peak = std::max(peak, std::abs(y));
            }
            peaks[cursor] = peak;
            bool protectedPath = current.config.protect || (transition > 0 && next.config.protect);
            int out = (cursor + 1) % (lookahead + 1);
            double gain = 1 - (1 - limiterGain) * release;
            if (protectedPath) {
                // Plan a linear attack to each approaching peak. Its final step guarantees
                // the owned PCM ceiling without clipping/saturation. Linked across channels.
                for (int distance = 0; distance <= lookahead; ++distance) {
                    double p = peaks[(out + distance) % (lookahead + 1)];
                    double required = p > ceiling ? ceiling / p : 1;
                    if (required < gain) gain = std::min(gain, limiterGain + (required - limiterGain) / (distance + 1));
                }
            }
            limiterGain = protectedPath ? gain : 1;
            if (protectedPath && peak > ceiling) overloads.fetch_add(1, std::memory_order_relaxed);
            for (int c = 0; c < count; ++c) data[c][frame] = float(delayed[c][out] * limiterGain);
            cursor = out;
            if (transition > 0 && --transition == 0) current = next;
        }
    }
};
}
