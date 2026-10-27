#pragma once
// daw::Result<T>: the return type of non-RT engine APIs (00-conventions §4). Shaped like
// std::expected, which C++20 lacks. RT code never returns a Result: it can't fail, it outputs
// silence and bumps a telemetry counter instead.

#include <cstdint>
#include <string>
#include <type_traits>
#include <utility>
#include <variant>
#include <vector>

namespace daw {

using NodeID = uint64_t;  // same alias as core/Node.h, which this header shouldn't pull in

enum class ErrorCode : uint32_t {
    invalidArgument,
    outOfMemory,
    notFound,
    unsupported,
    io,
    internal,
    cycle,  // MIX-002: the routing has a feedback loop; Error::nodes lists the NodeIDs on it
};

struct Error {
    ErrorCode code;
    std::string message;
    std::vector<NodeID> nodes = {};  // ErrorCode::cycle: the NodeIDs on the cycle, ascending
};

inline Error makeError(ErrorCode code, std::string message = {}) {
    return Error{code, std::move(message)};
}

// MIX-002 (DW-050). The message repeats the IDs ("cycle: 2, 3, 4") for logs.
inline Error makeCycleError(std::vector<NodeID> nodes) {
    std::string message = "cycle:";
    for (size_t i = 0; i < nodes.size(); ++i) message += (i ? ", " : " ") + std::to_string(nodes[i]);
    return Error{ErrorCode::cycle, std::move(message), std::move(nodes)};
}

template <class T>
class [[nodiscard]] Result {
    static_assert(!std::is_same_v<std::remove_cv_t<T>, Error>, "Result<Error> is ambiguous");
    static_assert(!std::is_reference_v<T>, "Result holds values; use a pointer for references");

public:
    // Converting, so `return std::make_unique<Derived>();` works for Result<unique_ptr<Base>>.
    template <class U = T>
        requires(std::is_constructible_v<T, U &&> &&
                 !std::is_same_v<std::remove_cvref_t<U>, Result> &&
                 !std::is_same_v<std::remove_cvref_t<U>, Error>)
    Result(U&& value) : storage_(std::in_place_index<0>, std::forward<U>(value)) {}
    Result(Error error) : storage_(std::in_place_index<1>, std::move(error)) {}

    bool ok() const { return storage_.index() == 0; }
    explicit operator bool() const { return ok(); }

    // value() on an error, or error() on a value, is a programming error and traps. std::get
    // would throw instead, and exceptions don't cross module boundaries (CONV §1).
    T& value() & { return *checked<0>(); }
    const T& value() const& { return *checked<0>(); }
    T&& value() && { return std::move(*checked<0>()); }

    const Error& error() const { return *checked<1>(); }

    template <class U>
    T valueOr(U&& fallback) const& {
        return ok() ? value() : static_cast<T>(std::forward<U>(fallback));
    }
    template <class U>
    T valueOr(U&& fallback) && {
        return ok() ? std::move(*this).value() : static_cast<T>(std::forward<U>(fallback));
    }

    T& operator*() & { return value(); }
    const T& operator*() const& { return value(); }
    T&& operator*() && { return std::move(*this).value(); }
    T* operator->() { return &value(); }
    const T* operator->() const { return &value(); }

private:
    template <std::size_t I>
    auto* checked() {
        auto* p = std::get_if<I>(&storage_);
        if (!p) __builtin_trap();
        return p;
    }
    template <std::size_t I>
    const auto* checked() const {
        const auto* p = std::get_if<I>(&storage_);
        if (!p) __builtin_trap();
        return p;
    }

    std::variant<T, Error> storage_;
};

// Success carries no value: `return {};` succeeds, `return makeError(...)` fails.
template <>
class [[nodiscard]] Result<void> {
public:
    Result() = default;
    Result(Error error) : error_(std::move(error)), ok_(false) {}

    bool ok() const { return ok_; }
    explicit operator bool() const { return ok_; }

    // Like Result<T>::error(): traps when called on success.
    const Error& error() const {
        if (ok_) __builtin_trap();
        return error_;
    }

private:
    Error error_{ErrorCode::internal, {}};
    bool ok_ = true;
};

} // namespace daw
