#include "package.hpp"
#include <windows.h>
#include <bcrypt.h>
#include <array>
#include <fstream>
#include <stdexcept>

namespace coop {
namespace {
// Queries hash many small records (manifests, install records, version tree stamps). Opening
// the CNG provider per file dominated local list time, so the shared provider is opened once
// per process. The handle lives until process exit; the operating system releases it then.
BCRYPT_ALG_HANDLE sha256_algorithm() {
    static const auto algorithm = [] {
        BCRYPT_ALG_HANDLE handle = nullptr;
        if (BCryptOpenAlgorithmProvider(&handle,BCRYPT_SHA256_ALGORITHM,nullptr,0) < 0)
            throw std::runtime_error("Cannot open SHA256 provider");
        return handle;
    }();
    return algorithm;
}
BCRYPT_ALG_HANDLE digest_algorithm(ir::DigestAlgorithm algorithm) {
    const auto open = [](LPCWSTR name) {
        BCRYPT_ALG_HANDLE handle = nullptr;
        if (BCryptOpenAlgorithmProvider(&handle,name,nullptr,0) < 0)
            throw std::runtime_error("Cannot open the declared digest provider");
        return handle;
    };
    switch (algorithm) {
    case ir::DigestAlgorithm::sha256: { static const auto handle = open(BCRYPT_SHA256_ALGORITHM); return handle; }
    case ir::DigestAlgorithm::sha512: { static const auto handle = open(BCRYPT_SHA512_ALGORITHM); return handle; }
    case ir::DigestAlgorithm::sha1: { static const auto handle = open(BCRYPT_SHA1_ALGORITHM); return handle; }
    case ir::DigestAlgorithm::md5: { static const auto handle = open(BCRYPT_MD5_ALGORITHM); return handle; }
    case ir::DigestAlgorithm::missing:
    case ir::DigestAlgorithm::other:
        break;
    }
    throw std::runtime_error("The declared digest algorithm has no native implementation");
}
std::size_t digest_size(ir::DigestAlgorithm algorithm) {
    switch (algorithm) {
    case ir::DigestAlgorithm::sha256: return 32;
    case ir::DigestAlgorithm::sha512: return 64;
    case ir::DigestAlgorithm::sha1: return 20;
    case ir::DigestAlgorithm::md5: return 16;
    case ir::DigestAlgorithm::missing:
    case ir::DigestAlgorithm::other:
        break;
    }
    throw std::runtime_error("The declared digest algorithm has no native implementation");
}
std::string digest_text(const unsigned char* digest, std::size_t size) {
    const char hex[] = "0123456789abcdef";
    std::string result;
    result.reserve(size*2);
    for (std::size_t index = 0; index < size; ++index) {
        result += hex[digest[index] >> 4];
        result += hex[digest[index] & 15];
    }
    return result;
}
}
std::string sha256_text(const std::string& value) {
    const auto algorithm = sha256_algorithm();
    BCRYPT_HASH_HANDLE hash = nullptr;
    if (BCryptCreateHash(algorithm,&hash,nullptr,0,nullptr,0,0) < 0)
        throw std::runtime_error("Cannot create SHA256 hash");
    try {
        if (!value.empty() && BCryptHashData(hash,reinterpret_cast<PUCHAR>(const_cast<char*>(value.data())),
                static_cast<ULONG>(value.size()),0) < 0)
            throw std::runtime_error("SHA256 data failed");
        std::array<unsigned char,32> digest{};
        if (BCryptFinishHash(hash,digest.data(),static_cast<ULONG>(digest.size()),0) < 0)
            throw std::runtime_error("SHA256 finish failed");
        BCryptDestroyHash(hash);
        return digest_text(digest.data(),digest.size());
    } catch (...) {
        BCryptDestroyHash(hash);
        throw;
    }
}
std::string digest_file(const fs::path& path, ir::DigestAlgorithm algorithm) {
    const auto provider = digest_algorithm(algorithm);
    BCRYPT_HASH_HANDLE hash = nullptr;
    if (BCryptCreateHash(provider,&hash,nullptr,0,nullptr,0,0) < 0)
        throw std::runtime_error("Cannot create the declared digest hash");
    try {
        std::ifstream input(path,std::ios::binary);
        if (!input) throw std::runtime_error("Cannot open file for digest verification");
        std::array<char,65536> buffer{};
        while (input) {
            input.read(buffer.data(),buffer.size());
            const auto count = input.gcount();
            if (count && BCryptHashData(hash,reinterpret_cast<PUCHAR>(buffer.data()),static_cast<ULONG>(count),0) < 0)
                throw std::runtime_error("Digest read failed");
        }
        if (!input.eof()) throw std::runtime_error("File read failed while hashing");
        std::vector<unsigned char> digest(digest_size(algorithm));
        if (BCryptFinishHash(hash,digest.data(),static_cast<ULONG>(digest.size()),0) < 0)
            throw std::runtime_error("Digest finish failed");
        BCryptDestroyHash(hash);
        return digest_text(digest.data(),digest.size());
    } catch (...) {
        BCryptDestroyHash(hash);
        throw;
    }
}
std::string sha256_file(const fs::path& path) {
    return digest_file(path,ir::DigestAlgorithm::sha256);
}
}
