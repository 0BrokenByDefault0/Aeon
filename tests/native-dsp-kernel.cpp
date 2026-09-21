#include "../ios/App/App/Audio/AeonDSPKernel.hpp"
#include <cassert>
#include <iostream>
#include <vector>

int main() {
    using namespace AeonDSP;
    Kernel reference; Configuration unity; reference.prepare(48000); reference.submit(unity);
    std::vector<float> left(32768 + lookahead), right(left.size());
    for (int i=0; i<32768; ++i) left[i]=right[i]=float(0.2*std::sin(i*0.13));
    auto original=left; float* data[]={left.data(),right.data()};
    reference.process(data,2,int(left.size()));
    for (int i=0;i<32768;++i) { assert(left[i+lookahead]==original[i]); assert(right[i+lookahead]==original[i]); }
    std::cout << "PASS float32 unity: exact equality, 32768 frames, 128-frame alignment\n";

    Kernel protection; Configuration protectedConfig; protectedConfig.protect=true;
    protection.prepare(48000); protection.submit(protectedConfig);
    double worst=0;
    for (int block=0;block<120;++block) {
        std::vector<float> a(512),b(512);
        for (int i=0;i<512;++i) {
            int n=block*512+i;
            a[i]=float(4*std::sin(n*0.31)+2*std::cos(n*2.1));
            b[i]=n%101==0?12:0;
        }
        float* channels[]={a.data(),b.data()}; protection.process(channels,2,512);
        for (int i=0;i<512;++i) { assert(std::isfinite(a[i]) && std::isfinite(b[i])); worst=std::max(worst,double(std::max(std::abs(a[i]),std::abs(b[i])))); }
    }
    assert(worst <= std::pow(10.,-1./20)+1e-7);
    std::cout << "PASS hot stereo multitone/impulses: worst " << 20*std::log10(worst) << " dBFS sample peak (not true peak)\n";

    Kernel bank; bank.prepare(48000);
    for(int block=0;block<100;++block) {
        Configuration c; c.count=20; c.gain=0.1; c.protect=true;
        for (int i=0;i<20;++i) c.coefficients[i][0]=block%2?1.1:1.;
        // A paused graph may receive thousands of edits: the mailbox retains newest.
        for(int i=0;i<1000;++i) assert(bank.submit(c));
        float a[512],b[512]; for(int i=0;i<512;++i) a[i]=b[i]=0.5f;
        float* channels[]={a,b}; bank.process(channels,2,512);
        for(int i=0;i<512;++i) { assert(std::isfinite(a[i])); assert(std::abs(a[i])<=0.8912511); }
    }
    std::cout << "PASS 20-filter transitions and 100000 coalesced parameter snapshots\n";
}
