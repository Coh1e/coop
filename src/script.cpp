#include "script.hpp"
#include <windows.h>
#include <algorithm>
#include <array>
#include <cctype>
#include <cstdio>
#include <fstream>
#include <map>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace coop {
namespace {
constexpr std::size_t max_script_bytes = 1024*1024;
constexpr std::size_t max_captured_bytes = 4*1024*1024;

std::string lower_text(std::string value) {
    for (auto& character : value) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    return value;
}

// --- lexer -------------------------------------------------------------------
enum class Tok { word, variable, string, parameter, op, pipe, lparen, array_lparen, rparen, lbrace, rbrace,
                 comma, semicolon, newline, assign, bang, dot, end };
struct Segment { bool variable = false; std::string text; };
struct Token { Tok kind = Tok::end; std::string text; std::vector<Segment> segments; int line = 1; };

bool is_name_start(char value) {
    return std::isalpha(static_cast<unsigned char>(value)) != 0 || value == '_';
}
bool is_name_char(char value) {
    return std::isalnum(static_cast<unsigned char>(value)) != 0 || value == '_';
}
bool is_word_char(char value) {
    return std::isalnum(static_cast<unsigned char>(value)) != 0 || value == '_' || value == '-';
}

bool lex(const std::string& text, std::vector<Token>& tokens, std::string& error) {
    const auto fail = [&](const char* reason) {
        error = reason;
        return false;
    };
    std::size_t index = 0;
    int line = 1;
    while (index < text.size()) {
        const char current = text[index];
        if (current == '\r') { ++index; continue; }
        if (current == '\n') { tokens.push_back({Tok::newline,{}, {}, line}); ++line; ++index; continue; }
        if (current == ' ' || current == '\t') { ++index; continue; }
        if (current == '#' || (current == '<' && index+1 < text.size() && text[index+1] == '#')) {
            // The sample corpus only uses single-line comments; block comments are outside the
            // proven subset and are reported instead of silently skipped.
            if (current == '<') return fail("block comments are outside the proven hook subset");
            while (index < text.size() && text[index] != '\n') ++index;
            continue;
        }
        if (current == '(') { tokens.push_back({Tok::lparen,{}, {}, line}); ++index; continue; }
        if (current == ')') { tokens.push_back({Tok::rparen,{}, {}, line}); ++index; continue; }
        if (current == '{') { tokens.push_back({Tok::lbrace,{}, {}, line}); ++index; continue; }
        if (current == '}') { tokens.push_back({Tok::rbrace,{}, {}, line}); ++index; continue; }
        if (current == ',') { tokens.push_back({Tok::comma,{}, {}, line}); ++index; continue; }
        if (current == ';') { tokens.push_back({Tok::semicolon,{}, {}, line}); ++index; continue; }
        if (current == '|') { tokens.push_back({Tok::pipe,{}, {}, line}); ++index; continue; }
        if (current == '=') { tokens.push_back({Tok::assign,{}, {}, line}); ++index; continue; }
        if (current == '!') { tokens.push_back({Tok::bang,{}, {}, line}); ++index; continue; }
        if (current == '.') { tokens.push_back({Tok::dot,{}, {}, line}); ++index; continue; }
        if (current == '@') {
            if (index+1 >= text.size() || text[index+1] != '(') return fail("hashtables and splatting are outside the proven hook subset");
            tokens.push_back({Tok::array_lparen,{}, {}, line});
            index += 2;
            continue;
        }
        if (current == '$') {
            std::size_t cursor = index+1;
            if (cursor < text.size() && (text[cursor] == '(' || text[cursor] == '{'))
                return fail("PowerShell subexpressions and braced variables are outside the proven hook subset");
            if (cursor >= text.size() || !is_name_start(text[cursor]))
                return fail("lone '$' is outside the proven hook subset");
            const auto start = cursor;
            while (cursor < text.size() && is_name_char(text[cursor])) ++cursor;
            std::string name = text.substr(start,cursor-start);
            if (name == "env" && cursor < text.size() && text[cursor] == ':') {
                ++cursor;
                const auto env_start = cursor;
                while (cursor < text.size() && is_name_char(text[cursor])) ++cursor;
                if (cursor == env_start) return fail("environment variable name is empty");
                name = "env:"+text.substr(env_start,cursor-env_start);
            }
            tokens.push_back({Tok::variable,name, {}, line});
            index = cursor;
            continue;
        }
        if (current == '-') {
            if (index+1 >= text.size() || !is_name_start(text[index+1])) return fail("'-' is only accepted for named parameters and comparison operators");
            std::size_t cursor = index+1;
            while (cursor < text.size() && is_name_char(text[cursor])) ++cursor;
            auto name = lower_text(text.substr(index+1,cursor-index-1));
            index = cursor;
            static const std::set<std::string> operators = {"eq","ne","and","or","not","match","notmatch","like","notlike"};
            if (operators.contains(name)) tokens.push_back({Tok::op,name, {}, line});
            else tokens.push_back({Tok::parameter,name, {}, line});
            continue;
        }
        if (current == '\'') {
            std::size_t cursor = index+1;
            std::string literal;
            bool closed = false;
            while (cursor < text.size()) {
                if (text[cursor] == '\n') break;
                if (text[cursor] == '\'') {
                    if (cursor+1 < text.size() && text[cursor+1] == '\'') { literal += '\''; cursor += 2; continue; }
                    closed = true; ++cursor; break;
                }
                literal += text[cursor]; ++cursor;
            }
            if (!closed) return fail("unterminated single-quoted string");
            Token token{Tok::string,{}, {}, line};
            token.segments.push_back({false,literal});
            tokens.push_back(std::move(token));
            index = cursor;
            continue;
        }
        if (current == '"') {
            std::size_t cursor = index+1;
            std::vector<Segment> segments;
            std::string literal;
            const auto flush = [&]() {
                if (literal.empty()) return;
                segments.push_back({false,literal});
                literal.clear();
            };
            bool closed = false;
            while (cursor < text.size()) {
                const char value = text[cursor];
                if (value == '\n') break;
                if (value == '`') {
                    if (cursor+1 >= text.size()) return fail("unterminated escape sequence");
                    const char escaped = text[cursor+1];
                    switch (escaped) {
                    case 'n': literal += '\n'; break;
                    case 'r': literal += '\r'; break;
                    case 't': literal += '\t'; break;
                    case '0': literal += '\0'; break;
                    case 'a': literal += '\a'; break;
                    case 'b': literal += '\b'; break;
                    case 'f': literal += '\f'; break;
                    case 'v': literal += '\v'; break;
                    default: literal += escaped; break;
                    }
                    cursor += 2;
                    continue;
                }
                if (value == '"') {
                    if (cursor+1 < text.size() && text[cursor+1] == '"') { literal += '"'; cursor += 2; continue; }
                    closed = true; ++cursor; break;
                }
                if (value == '$') {
                    std::size_t name_start = cursor+1;
                    if (name_start < text.size() && (text[name_start] == '(' || text[name_start] == '{'))
                        return fail("PowerShell subexpressions in strings are outside the proven hook subset");
                    if (name_start >= text.size() || !is_name_start(text[name_start])) { literal += '$'; ++cursor; continue; }
                    while (name_start < text.size() && is_name_char(text[name_start])) ++name_start;
                    std::string name = text.substr(cursor+1,name_start-cursor-1);
                    cursor = name_start;
                    if (name == "env" && cursor < text.size() && text[cursor] == ':') {
                        ++cursor;
                        const auto env_start = cursor;
                        while (cursor < text.size() && is_name_char(text[cursor])) ++cursor;
                        if (cursor == env_start) return fail("environment variable name is empty");
                        name = "env:"+text.substr(env_start,cursor-env_start);
                    }
                    flush();
                    segments.push_back({true,name});
                    continue;
                }
                literal += value; ++cursor;
            }
            if (!closed) return fail("unterminated double-quoted string");
            flush();
            Token token{Tok::string,{}, {}, line};
            token.segments = std::move(segments);
            tokens.push_back(std::move(token));
            index = cursor;
            continue;
        }
        if (is_name_start(current)) {
            std::size_t cursor = index;
            while (cursor < text.size() && is_word_char(text[cursor])) ++cursor;
            tokens.push_back({Tok::word,text.substr(index,cursor-index), {}, line});
            index = cursor;
            continue;
        }
        return fail("character is outside the proven hook subset");
    }
    tokens.push_back({Tok::end,{}, {}, line});
    return true;
}

// --- static compatibility checker -------------------------------------------
struct Value {
    enum class Kind { path, text } kind = Kind::text;
    bool parent = false;
    static Value rooted(bool has_parent = false) { return {Kind::path,has_parent}; }
    static Value plain(bool has_parent = false) { return {Kind::text,has_parent}; }
};

// Rebuilds the literal shape of a string token with variables replaced by a placeholder so a
// literal `..` path component can be detected without trying to evaluate the script.
bool parent_component(const Token& token) {
    std::string shape;
    for (const auto& segment : token.segments) shape += segment.variable ? std::string("V") : segment.text;
    std::string component;
    const auto flush = [&]() -> bool {
        const bool result = component == "..";
        component.clear();
        return result;
    };
    for (const auto character : shape) {
        if (character == '\\' || character == '/') { if (flush()) return true; }
        else component += character;
    }
    return flush();
}

class Checker {
public:
    Checker(const std::vector<Token>& tokens, std::string& error) : tokens_(tokens), error_(error) {}
    bool run() {
        skip_separators();
        while (!at(Tok::end)) {
            if (!statement()) return false;
            skip_separators();
        }
        return true;
    }
    const std::set<std::string>& commands() const { return commands_; }
    const std::set<std::string>& helpers() const { return helpers_; }

private:
    const Token& peek(std::size_t offset = 0) const {
        const auto position = index_+offset < tokens_.size() ? index_+offset : tokens_.size()-1;
        return tokens_[position];
    }
    bool at(Tok kind) const { return peek().kind == kind; }
    bool at_word(const char* value) const { return peek().kind == Tok::word && lower_text(peek().text) == lower_text(value); }
    const Token& advance() { const auto& token = tokens_[index_]; if (index_+1 < tokens_.size()) ++index_; return token; }
    bool accept(Tok kind) { if (!at(kind)) return false; advance(); return true; }
    bool expect(Tok kind, const char* what) {
        if (accept(kind)) return true;
        return fail(std::string("expected ")+what);
    }
    bool fail(const std::string& message) {
        if (error_.empty()) error_ = "line "+std::to_string(peek().line)+": "+message;
        return false;
    }
    static bool is_separator(Tok kind) {
        return kind == Tok::newline || kind == Tok::semicolon || kind == Tok::pipe ||
               kind == Tok::rparen || kind == Tok::rbrace || kind == Tok::end;
    }
    void skip_separators() { while (at(Tok::newline) || at(Tok::semicolon)) advance(); }

    bool statement() {
        if (at_word("if")) return if_statement();
        if (at_word("else") || at_word("elseif") || at_word("foreach") || at_word("while") || at_word("function") ||
            at_word("try") || at_word("catch") || at_word("switch") || at_word("return") || at_word("throw") ||
            at_word("break") || at_word("continue") || at_word("exit") || at_word("param") || at_word("Set-StrictMode"))
            return fail("'"+peek().text+"' is outside the proven hook subset");
        if (at(Tok::variable) && peek(1).kind == Tok::assign) return assignment();
        Value ignored;
        return pipeline(ignored);
    }
    bool assignment() {
        const auto name = advance().text;
        advance(); // '='
        if (name == "null") {
            Value ignored;
            return pipeline(ignored);
        }
        if (rooted_context(name) || name == "app" || name == "bucket" || name == "version" ||
            name == "architecture" || name == "fname" || name == "global" || name == "cmd")
            return fail("the hook context variable $"+name+" is read-only");
        Value value;
        if (!pipeline(value)) return false;
        variables_[name] = value.kind == Value::Kind::path;
        parents_[name] = value.parent;
        return true;
    }
    bool if_statement() {
        advance(); // if
        if (!expect(Tok::lparen,"'(' after if")) return false;
        Value condition;
        if (!pipeline(condition)) return false;
        if (!expect(Tok::rparen,"')' after the if condition")) return false;
        if (!block()) return false;
        for (;;) {
            if (at_word("elseif")) {
                advance();
                if (!expect(Tok::lparen,"'(' after elseif")) return false;
                if (!pipeline(condition)) return false;
                if (!expect(Tok::rparen,"')' after the elseif condition")) return false;
                if (!block()) return false;
                continue;
            }
            if (at_word("else")) {
                advance();
                if (!block()) return false;
            }
            break;
        }
        return true;
    }
    bool block() {
        if (!expect(Tok::lbrace,"'{'")) return false;
        skip_separators();
        while (!at(Tok::rbrace)) {
            if (at(Tok::end)) return fail("unterminated block");
            if (!statement()) return false;
            skip_separators();
        }
        advance(); // '}'
        return true;
    }
    bool pipeline(Value& result) {
        if (!item(result)) return false;
        while (accept(Tok::pipe)) {
            if (at_word("ForEach-Object")) {
                advance();
                const auto saved = variables_;
                const auto saved_parents = parents_;
                variables_["_"] = false;
                variables_["PSItem"] = false;
                parents_["_"] = false;
                parents_["PSItem"] = false;
                if (!block()) return false;
                variables_ = saved;
                parents_ = saved_parents;
                result = Value::plain();
                continue;
            }
            if (at_word("Out-Null")) {
                advance();
                result = Value::plain();
                continue;
            }
            return fail("only ForEach-Object and Out-Null are supported after '|'");
        }
        return true;
    }
    bool item(Value& result) {
        if (at(Tok::word)) {
            const auto name = peek().text;
            return command(name,result);
        }
        return expression(result);
    }
    bool expression(Value& result) {
        if (!or_expression(result)) return false;
        while (accept(Tok::comma)) {
            Value next;
            if (!or_expression(next)) return false;
            result = Value::plain();
        }
        return true;
    }
    bool or_expression(Value& result) {
        if (!and_expression(result)) return false;
        while (at(Tok::op) && peek().text == "or") {
            advance();
            Value next;
            if (!and_expression(next)) return false;
            result = Value::plain();
        }
        return true;
    }
    bool and_expression(Value& result) {
        if (!not_expression(result)) return false;
        while (at(Tok::op) && peek().text == "and") {
            advance();
            Value next;
            if (!not_expression(next)) return false;
            result = Value::plain();
        }
        return true;
    }
    bool not_expression(Value& result) {
        if (at(Tok::bang) || (at(Tok::op) && peek().text == "not")) {
            advance();
            Value inner;
            if (!not_expression(inner)) return false;
            result = Value::plain();
            return true;
        }
        return comparison_expression(result);
    }
    bool comparison_expression(Value& result) {
        if (!primary(result)) return false;
        static const std::set<std::string> comparisons = {"eq","ne","match","notmatch","like","notlike"};
        while (at(Tok::op) && comparisons.contains(peek().text)) {
            advance();
            Value right;
            if (!primary(right)) return false;
            result = Value::plain();
        }
        return true;
    }
    bool primary(Value& result) {
        if (at(Tok::string)) {
            const auto& token = advance();
            result = string_value(token);
        } else if (at(Tok::variable)) {
            const auto name = advance().text;
            if (name.starts_with("env:"))
                return fail("environment variable $"+name+" is outside the proven hook context");
            if (name == "_" || name == "PSItem") result = Value::plain();
            else {
                const auto found = variables_.find(name);
                if (found == variables_.end())
                    return fail("variable $"+name+" is outside the proven hook context");
                const auto parent = parents_.find(name);
                const bool has_parent = parent != parents_.end() && parent->second;
                result = found->second ? Value::rooted(has_parent) : Value::plain(has_parent);
            }
        } else if (accept(Tok::lparen)) {
            if (!pipeline(result)) return false;
            if (!expect(Tok::rparen,"')'")) return false;
        } else if (accept(Tok::array_lparen)) {
            if (!expression(result)) return false;
            if (!expect(Tok::rparen,"')' after the array")) return false;
            result = Value::plain();
        } else if (at(Tok::word)) {
            advance();
            result = Value::plain();
        } else {
            return fail("expression is outside the proven hook subset");
        }
        for (;;) {
            if (!accept(Tok::dot)) break;
            if (!at(Tok::word)) return fail("member access requires a name");
            const auto member = advance().text;
            if (member != "Replace")
                return fail("member '"+member+"' is outside the proven hook subset");
            if (!expect(Tok::lparen,"'(' after .Replace")) return false;
            Value first;
            if (!or_expression(first)) return false;
            if (!expect(Tok::comma,"',' between .Replace arguments")) return false;
            Value second;
            if (!or_expression(second)) return false;
            if (!expect(Tok::rparen,"')' after .Replace arguments")) return false;
            result = Value::plain();
        }
        return true;
    }
    Value string_value(const Token& token) const {
        const bool has_parent = parent_component(token);
        if (!token.segments.empty() && token.segments.front().variable) {
            const auto& name = token.segments.front().text;
            if (rooted_context(name)) return Value::rooted(has_parent);
            const auto found = variables_.find(name);
            if (found != variables_.end() && found->second) return Value::rooted(has_parent);
        }
        return Value::plain(has_parent);
    }
    bool rooted_context(const std::string& name) const {
        return name == "dir" || name == "original_dir" || name == "persist_dir" || name == "bucketsdir";
    }
    bool require_path(const Value& value, const std::string& what) {
        if (value.kind != Value::Kind::path)
            return fail(what+" must resolve under $dir, $original_dir, $persist_dir or $bucketsdir");
        if (value.parent)
            return fail(what+" must not contain a parent-directory component");
        return true;
    }
    bool allowed(const std::string& name, const std::map<std::string,Value>& named, const std::set<std::string>& allowed_names) {
        for (const auto& [key,value] : named) {
            (void)value;
            if (!allowed_names.contains(key)) return fail(name+" parameter -"+key+" is outside the proven subset");
        }
        return true;
    }
    const Value* find(const std::map<std::string,Value>& named, const char* first, const char* second = nullptr) const {
        for (const auto* key : {first,second}) {
            if (!key) continue;
            const auto found = named.find(key);
            if (found != named.end()) return &found->second;
        }
        return nullptr;
    }
    bool command(const std::string& raw, Value& result) {
        const auto name = lower_text(raw);
        static const std::set<std::string> commands = {"test-path","get-content","set-content","new-item","copy-item",
            "remove-item","join-path","split-path","out-null"};
        static const std::set<std::string> helpers = {"ensure","info","warn"};
        const bool known_command = commands.contains(name);
        const bool known_helper = helpers.contains(name);
        if (!known_command && !known_helper)
            return fail("command '"+raw+"' is not in the proven hook helper set");
        advance(); // command name
        std::map<std::string,Value> named;
        std::vector<Value> positional;
        while (!is_separator(peek().kind)) {
            if (at(Tok::parameter)) {
                auto parameter = advance().text;
                static const std::set<std::string> flags = {"force","recurse","raw","parent","nonewline","leaf"};
                if (flags.contains(parameter)) { named[parameter] = Value::plain(); continue; }
                Value value;
                if (!expression(value)) return false;
                named[parameter] = value;
                continue;
            }
            Value value;
            if (!expression(value)) return false;
            positional.push_back(value);
        }
        if (known_helper) {
            if (name == "ensure") {
                if (positional.size() != 1) return fail("ensure requires exactly one directory");
                if (!require_path(positional.front(),"ensure path")) return false;
            } else {
                if (positional.size() != 1) return fail(name+" requires exactly one message");
                if (!named.empty()) return fail(name+" does not accept named parameters in the proven subset");
            }
            helpers_.insert(name);
            result = Value::plain();
            return true;
        }
        commands_.insert(raw);
        const auto positional_path = [&](std::size_t position) -> const Value* {
            return position < positional.size() ? &positional[position] : nullptr;
        };
        if (name == "out-null") {
            if (!positional.empty() || !named.empty()) return fail("Out-Null does not accept arguments");
            result = Value::plain();
            return true;
        }
        if (name == "test-path") {
            if (!allowed(raw,named,{"path","literalpath","pathtype"})) return false;
            if (positional.size() > 1) return fail("Test-Path accepts at most one positional path");
            const auto* path = find(named,"path","literalpath");
            if (!path) path = positional_path(0);
            if (!path) return fail("Test-Path requires a path");
            if (!require_path(*path,"Test-Path path")) return false;
            result = Value::plain();
            return true;
        }
        if (name == "get-content") {
            if (!allowed(raw,named,{"path","literalpath","encoding","raw"})) return false;
            if (positional.size() > 1) return fail("Get-Content accepts at most one positional path");
            const auto* path = find(named,"path","literalpath");
            if (!path) path = positional_path(0);
            if (!path) return fail("Get-Content requires a path");
            if (!require_path(*path,"Get-Content path")) return false;
            result = Value::plain();
            return true;
        }
        if (name == "set-content") {
            if (!allowed(raw,named,{"path","value","encoding","force","nonewline"})) return false;
            const auto* path = find(named,"path");
            if (!path) {
                if (positional.empty()) return fail("Set-Content requires a path");
                path = positional_path(0);
            }
            if (!require_path(*path,"Set-Content path")) return false;
            if (positional.size() > 2) return fail("Set-Content accepts at most a path and a value");
            result = Value::plain();
            return true;
        }
        if (name == "new-item") {
            if (!allowed(raw,named,{"path","itemtype","force","value"})) return false;
            if (positional.size() > 1) return fail("New-Item accepts at most one positional path");
            const auto* path = find(named,"path");
            if (!path) path = positional_path(0);
            if (!path) return fail("New-Item requires a path");
            if (!require_path(*path,"New-Item path")) return false;
            result = Value::plain();
            return true;
        }
        if (name == "copy-item") {
            if (!allowed(raw,named,{"path","destination","force","recurse"})) return false;
            if (positional.size() > 2) return fail("Copy-Item accepts at most a source and a destination");
            const auto* source = find(named,"path");
            if (!source) source = positional_path(0);
            const auto* destination = find(named,"destination");
            if (!destination) destination = positional_path(1);
            if (!source || !destination) return fail("Copy-Item requires a source and a destination");
            if (!require_path(*source,"Copy-Item source") || !require_path(*destination,"Copy-Item destination")) return false;
            result = Value::plain();
            return true;
        }
        if (name == "remove-item") {
            if (!allowed(raw,named,{"path","literalpath","recurse","force"})) return false;
            if (positional.size() > 1) return fail("Remove-Item accepts at most one positional path");
            const auto* path = find(named,"path","literalpath");
            if (!path) path = positional_path(0);
            if (!path) return fail("Remove-Item requires a path");
            if (!require_path(*path,"Remove-Item path")) return false;
            result = Value::plain();
            return true;
        }
        if (name == "join-path") {
            if (!allowed(raw,named,{"path","childpath"})) return false;
            if (positional.size() > 2) return fail("Join-Path accepts at most a path and a child path");
            const auto* base = find(named,"path");
            if (!base) base = positional_path(0);
            const auto* child = find(named,"childpath");
            if (!child) child = positional_path(1);
            if (!base || !child) return fail("Join-Path requires a path and a child path");
            if (!require_path(*base,"Join-Path path")) return false;
            result = base->kind == Value::Kind::path ? Value::rooted(base->parent || child->parent) : Value::plain();
            return true;
        }
        if (name == "split-path") {
            if (!allowed(raw,named,{"path","parent","leaf"})) return false;
            if (positional.size() > 1) return fail("Split-Path accepts at most one positional path");
            const auto* path = find(named,"path");
            if (!path) path = positional_path(0);
            if (!path) return fail("Split-Path requires a path");
            if (!require_path(*path,"Split-Path path")) return false;
            result = path->kind == Value::Kind::path ? Value::rooted(path->parent) : Value::plain();
            return true;
        }
        return fail("command '"+raw+"' is not implemented by the proven hook subset");
    }
    const std::vector<Token>& tokens_;
    std::string& error_;
    std::size_t index_ = 0;
    std::map<std::string,bool> variables_ = {
        {"app",false},{"bucket",false},{"version",false},{"architecture",false},{"fname",false},
        {"global",false},{"cmd",false},
        {"dir",true},{"original_dir",true},{"persist_dir",true},{"bucketsdir",true}};
    std::map<std::string,bool> parents_;
    std::set<std::string> commands_;
    std::set<std::string> helpers_;
};

std::wstring quote_argument(const std::wstring& value) {
    if (!value.empty() && value.find_first_of(L" \t\n\v\"") == std::wstring::npos) return value;
    std::wstring result = L"\"";
    unsigned backslashes = 0;
    for (const auto character : value) {
        if (character == L'\\') { ++backslashes; continue; }
        if (character == L'"') result.append(backslashes*2+1,L'\\');
        else result.append(backslashes,L'\\');
        result += character;
        backslashes = 0;
    }
    result.append(backslashes*2,L'\\');
    result += L'"';
    return result;
}
std::string ps_literal(const std::string& value) {
    std::string result = "'";
    for (const auto character : value) {
        if (character == '\'') result += "''";
        else result += character;
    }
    result += '\'';
    return result;
}
std::string bootstrap(const Package& package, const fs::path& directory, const fs::path& original_directory,
                      const fs::path& persist_directory, const fs::path& buckets_directory, const std::string& command_name) {
    const auto fname = package.artifacts.empty() ? std::string{} : package.artifacts.front().filename;
    std::string text =
        "$ErrorActionPreference = 'Stop'\n"
        "$ProgressPreference = 'SilentlyContinue'\n"
        "try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }\n"
        "function ensure([string] $path) {\n"
        "    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }\n"
        "    (Resolve-Path -LiteralPath $path).Path\n"
        "}\n"
        "function info([string] $message) { Write-Host $message }\n"
        // Warnings keep Scoop's visible text but go to the child's stderr so a lifecycle hook's
        // two output channels stay distinguishable for people and for automation.
        "function warn([string] $message) { [Console]::Error.WriteLine('WARNING: ' + $message) }\n";
    const auto emit = [&](const char* name, const std::string& value) {
        text += "$"+std::string(name)+" = "+ps_literal(value)+"\n";
    };
    emit("app",package.name);
    emit("bucket",package.bucket);
    emit("version",package.version);
    emit("architecture",package.architecture);
    emit("fname",fname);
    emit("dir",path_text(directory));
    emit("original_dir",path_text(original_directory));
    emit("persist_dir",path_text(persist_directory));
    emit("bucketsdir",path_text(buckets_directory));
    emit("cmd",command_name);
    text += "$global = $false\n";
    return text;
}
struct FileHandle {
    HANDLE value = INVALID_HANDLE_VALUE;
    FileHandle() = default;
    explicit FileHandle(HANDLE handle) : value(handle) {}
    ~FileHandle() { if (value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    FileHandle(const FileHandle&) = delete;
    FileHandle& operator=(const FileHandle&) = delete;
    HANDLE release() { const auto result = value; value = INVALID_HANDLE_VALUE; return result; }
    void reset() { if (value != INVALID_HANDLE_VALUE) CloseHandle(value); value = INVALID_HANDLE_VALUE; }
};
void drain(HANDLE pipe, std::string& captured, bool echo, FILE* target) {
    std::array<char,65536> buffer{};
    for (;;) {
        DWORD count = 0;
        if (!ReadFile(pipe,buffer.data(),static_cast<DWORD>(buffer.size()),&count,nullptr) || count == 0) break;
        if (captured.size() < max_captured_bytes) captured.append(buffer.data(),count);
        if (echo && target) {
            std::fwrite(buffer.data(),1,count,target);
            std::fflush(target);
        }
    }
}
void write_text_file(const fs::path& path, const std::string& text) {
    std::ofstream output(path,std::ios::binary|std::ios::trunc);
    if (!output) throw std::runtime_error("Cannot write hook script log");
    output.write(text.data(),static_cast<std::streamsize>(text.size()));
    if (!output) throw std::runtime_error("Cannot finish hook script log");
}
void write_script_file(const fs::path& path, const std::string& text) {
    std::ofstream output(path,std::ios::binary|std::ios::trunc);
    if (!output) throw std::runtime_error("Cannot write hook script");
    // A BOM keeps the script text readable for both PowerShell 7 and Windows PowerShell 5.1,
    // which otherwise assumes the ANSI code page for BOM-less files.
    static const char bom[] = "\xEF\xBB\xBF";
    output.write(bom,3);
    output.write(text.data(),static_cast<std::streamsize>(text.size()));
    if (!output) throw std::runtime_error("Cannot finish hook script");
}
}
const char* script_phase_name(ScriptPhase phase) {
    switch (phase) {
    case ScriptPhase::before_install: return "pre_install";
    case ScriptPhase::installer: return "installer";
    case ScriptPhase::after_install: return "post_install";
    case ScriptPhase::before_uninstall: return "pre_uninstall";
    case ScriptPhase::uninstaller: return "uninstaller";
    case ScriptPhase::after_uninstall: return "post_uninstall";
    }
    return "unknown";
}
std::string script_json_text(const std::string& value) {
    std::string result;
    result.reserve(value.size());
    std::size_t index = 0;
    while (index < value.size()) {
        const auto lead = static_cast<unsigned char>(value[index]);
        if (lead < 0x80) { result += static_cast<char>(lead); ++index; continue; }
        std::size_t length = 0;
        unsigned minimum = 0;
        if ((lead & 0xE0) == 0xC0) { length = 2; minimum = 0x80; }
        else if ((lead & 0xF0) == 0xE0) { length = 3; minimum = 0x800; }
        else if ((lead & 0xF8) == 0xF0) { length = 4; minimum = 0x10000; }
        bool valid = length != 0 && index+length <= value.size();
        unsigned code = length == 2 ? (lead & 0x1Fu) : length == 3 ? (lead & 0x0Fu) : (lead & 0x07u);
        for (std::size_t offset = 1; valid && offset < length; ++offset) {
            const auto next = static_cast<unsigned char>(value[index+offset]);
            if ((next & 0xC0) != 0x80) valid = false;
            else code = (code << 6) | (next & 0x3Fu);
        }
        if (valid && (code < minimum || code > 0x10FFFFu || (code >= 0xD800u && code <= 0xDFFFu))) valid = false;
        if (!valid) { result += '?'; ++index; continue; }
        result.append(value,index,length);
        index += length;
    }
    return result;
}
bool ScriptCapability::compatible() const {
    return std::all_of(scripts.begin(),scripts.end(),[](const ScriptReport& report) { return report.compatible; });
}
std::vector<std::string> ScriptCapability::messages() const {
    std::vector<std::string> result;
    for (const auto& report : scripts)
        for (const auto& diagnostic : report.diagnostics) result.push_back(diagnostic.message);
    return result;
}
ScriptCapability check_package_scripts(const Package& package) {
    ScriptCapability capability;
    for (const auto& script : package.scripts) {
        ScriptReport report;
        report.phase = script.phase;
        const auto phase = std::string(script_phase_name(script.phase));
        if (script.phase != ScriptPhase::before_install && script.phase != ScriptPhase::after_install &&
            script.phase != ScriptPhase::before_uninstall) {
            report.compatible = false;
            report.diagnostics.push_back({DiagnosticKind::capability,"unsupported-script-phase",
                "The "+phase+" script phase is not enabled; only pre_install, post_install and pre_uninstall hooks are supported"});
        } else if (script.text.empty()) {
            report.compatible = false;
            report.diagnostics.push_back({DiagnosticKind::capability,"empty-script","The "+phase+" hook is empty"});
        } else if (script.text.size() > max_script_bytes) {
            report.compatible = false;
            report.diagnostics.push_back({DiagnosticKind::capability,"oversized-script",
                "The "+phase+" hook exceeds the "+std::to_string(max_script_bytes)+" byte limit"});
        } else {
            std::vector<Token> tokens;
            std::string error;
            if (!lex(script.text,tokens,error)) {
                report.compatible = false;
                report.diagnostics.push_back({DiagnosticKind::capability,"unsupported-script",
                    phase+" hook: "+error});
            } else {
                Checker checker(tokens,error);
                if (!checker.run()) {
                    report.compatible = false;
                    report.diagnostics.push_back({DiagnosticKind::capability,"unsupported-script",
                        phase+" hook "+error});
                } else {
                    report.commands.assign(checker.commands().begin(),checker.commands().end());
                    report.helpers.assign(checker.helpers().begin(),checker.helpers().end());
                }
            }
        }
        capability.scripts.push_back(std::move(report));
    }
    return capability;
}
std::optional<fs::path> powershell_interpreter() {
    wchar_t configured[32768]{};
    const auto configured_length = GetEnvironmentVariableW(L"COOP_POWERSHELL",configured,static_cast<DWORD>(std::size(configured)));
    if (configured_length && configured_length < std::size(configured)) {
        const fs::path candidate(configured);
        if (fs::is_regular_file(candidate)) return candidate;
        return std::nullopt;
    }
    std::vector<wchar_t> buffer(32768);
    const auto length = SearchPathW(nullptr,L"pwsh.exe",nullptr,static_cast<DWORD>(buffer.size()),buffer.data(),nullptr);
    if (length && length < buffer.size()) {
        const fs::path candidate(buffer.data());
        if (fs::is_regular_file(candidate)) return candidate;
    }
    wchar_t windows[32768]{};
    const auto windows_length = GetWindowsDirectoryW(windows,static_cast<UINT>(std::size(windows)));
    if (windows_length && windows_length < std::size(windows)) {
        const fs::path candidate = fs::path(windows)/L"System32"/L"WindowsPowerShell"/L"v1.0"/L"powershell.exe";
        if (fs::is_regular_file(candidate)) return candidate;
    }
    return std::nullopt;
}
ScriptRun run_package_script(const Context& context, const Package& package, std::size_t index,
                             const fs::path& directory, const fs::path& original_directory,
                             const fs::path& persist_directory, const fs::path& transaction,
                             const std::string& command_name) {
    const auto interpreter = powershell_interpreter();
    if (!interpreter) throw std::runtime_error("A PowerShell runtime (pwsh.exe or Windows PowerShell) is required for lifecycle hook scripts");
    const auto script = package.scripts.at(index);
    const auto phase = std::string(script_phase_name(script.phase));
    const auto scripts = transaction/L"scripts";
    std::error_code error;
    fs::create_directories(scripts,error);
    if (error) throw std::runtime_error("Cannot create the hook script directory");
    const auto base = scripts/(std::to_wstring(index)+L"-"+wide(phase));
    ScriptRun result;
    result.interpreter = *interpreter;
    result.hook_path = fs::path(base.wstring()+L".ps1");
    result.stdout_path = fs::path(base.wstring()+L".stdout.log");
    result.stderr_path = fs::path(base.wstring()+L".stderr.log");
    write_script_file(result.hook_path,
        bootstrap(package,directory,original_directory,persist_directory,
                  context.root/L"buckets",command_name)+script.text+"\n");
    SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES),nullptr,TRUE};
    FileHandle out_read, out_write, err_read, err_write;
    if (!CreatePipe(&out_read.value,&out_write.value,&attributes,0)) throw std::runtime_error("Cannot create the hook stdout pipe");
    if (!CreatePipe(&err_read.value,&err_write.value,&attributes,0)) throw std::runtime_error("Cannot create the hook stderr pipe");
    if (!SetHandleInformation(out_read.value,HANDLE_FLAG_INHERIT,0) || !SetHandleInformation(err_read.value,HANDLE_FLAG_INHERIT,0))
        throw std::runtime_error("Cannot isolate the hook output pipes");
    FileHandle input(CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&attributes,OPEN_EXISTING,0,nullptr));
    if (input.value == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot open the hook stdin device");
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES|STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    startup.hStdInput = input.value;
    startup.hStdOutput = out_write.value;
    startup.hStdError = err_write.value;
    auto command_line = quote_argument(interpreter->wstring())+L" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "+
        quote_argument(result.hook_path.wstring());
    std::wstring working_directory;
    if (fs::is_directory(directory)) working_directory = directory.wstring();
    else working_directory = context.root.wstring();
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(nullptr,command_line.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW,nullptr,
                        working_directory.c_str(),&startup,&process))
        throw std::runtime_error("Cannot start the PowerShell hook host (Windows error "+std::to_string(GetLastError())+")");
    FileHandle process_handle(process.hProcess);
    CloseHandle(process.hThread);
    out_write.reset();
    err_write.reset();
    const bool echo = !context.json_output;
    std::thread stdout_thread(drain,out_read.release(),std::ref(result.stdout_text),echo,stdout);
    std::thread stderr_thread(drain,err_read.release(),std::ref(result.stderr_text),echo,stderr);
    WaitForSingleObject(process_handle.value,INFINITE);
    DWORD exit_code = 1;
    GetExitCodeProcess(process_handle.value,&exit_code);
    stdout_thread.join();
    stderr_thread.join();
    result.exit_code = static_cast<int>(exit_code);
    write_text_file(result.stdout_path,result.stdout_text);
    write_text_file(result.stderr_path,result.stderr_text);
    return result;
}
}
