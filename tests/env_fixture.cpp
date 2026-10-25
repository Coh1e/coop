#define _CRT_SECURE_NO_WARNINGS
#include <cstdlib>
#include <iostream>

int main(int argc, char** argv) {
    std::cout << "env fixture";
    for (int index = 1; index < argc; ++index) std::cout << " [" << argv[index] << "]";
    const char* variable = std::getenv("FIXTURE_ENV");
    std::cout << " env=" << (variable ? variable : "<unset>") << "\n";
    return 0;
}
