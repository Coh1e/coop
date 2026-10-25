#include "package.hpp"
#include <windows.h>
#include <bcrypt.h>
#include <array>
#include <fstream>
#include <stdexcept>

namespace coop {
std::string sha256_file(const fs::path& path) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    if (BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0) < 0)
        throw std::runtime_error("Cannot open SHA256 provider");
    if (BCryptCreateHash(algorithm,&hash,nullptr,0,nullptr,0,0) < 0) {
        BCryptCloseAlgorithmProvider(algorithm,0);
        throw std::runtime_error("Cannot create SHA256 hash");
    }
    try {
        std::ifstream input(path,std::ios::binary);
        if (!input) throw std::runtime_error("Cannot open file for SHA256");
        std::array<char,65536> buffer{};
        while (input) {
            input.read(buffer.data(),buffer.size());
            const auto count = input.gcount();
            if (count && BCryptHashData(hash,reinterpret_cast<PUCHAR>(buffer.data()),static_cast<ULONG>(count),0) < 0)
                throw std::runtime_error("SHA256 read failed");
        }
        if (!input.eof()) throw std::runtime_error("File read failed while hashing");
        std::array<unsigned char,32> digest{};
        if (BCryptFinishHash(hash,digest.data(),static_cast<ULONG>(digest.size()),0) < 0)
            throw std::runtime_error("SHA256 finish failed");
        const char hex[] = "0123456789abcdef";
        std::string result;
        result.reserve(64);
        for (const auto byte : digest) { result += hex[byte >> 4]; result += hex[byte & 15]; }
        BCryptDestroyHash(hash);
        BCryptCloseAlgorithmProvider(algorithm,0);
        return result;
    } catch (...) {
        BCryptDestroyHash(hash);
        BCryptCloseAlgorithmProvider(algorithm,0);
        throw;
    }
}
}
