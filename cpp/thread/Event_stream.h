#pragma once
#include <functional>
#include <map>
#include <memory>
#include <unordered_map>

template <typename... Args> class Event_emitter;
template <typename... Args> class Event_stream;
template <typename... Args>
std::pair<std::shared_ptr<Event_stream<Args...>>, std::shared_ptr<Event_emitter<Args...>>>
make_event();

template <typename... Args> class Event_stream {
public:
    class Token;
    std::shared_ptr<Token> subscribe(std::function<void(Args...)> callback);

    Event_stream(const Event_stream&) = delete;
    Event_stream& operator=(const Event_stream&) = delete;

private:
    friend std::pair<std::shared_ptr<Event_stream<Args...>>,
                     std::shared_ptr<Event_emitter<Args...>>>
    make_event<Args...>();
    Event_stream(std::weak_ptr<Event_emitter<Args...>> emitter_) : emitter(std::move(emitter_)) {}
    std::weak_ptr<Event_emitter<Args...>> emitter;
};

template <typename... Args> class Event_emitter {
public:
    void emit(Args... args);

    Event_emitter() {}
    Event_emitter(const Event_emitter&) = delete;
    Event_emitter& operator=(const Event_emitter&) = delete;

private:
    friend class Event_stream<Args...>;
    friend class Event_stream<Args...>::Token;
    std::unordered_map<typename Event_stream<Args...>::Token*,
                       std::pair<std::weak_ptr<typename Event_stream<Args...>::Token>,
                                 std::function<void(Args...)>>>
        subscribers;
};

// Implementation details....

template <typename... Args> class Event_stream<Args...>::Token {
private:
    Token() {}
    Token(const Token&) = delete;
    Token& operator=(const Token&) = delete;
    friend class Event_stream<Args...>;
};

template <typename... Args>
std::shared_ptr<typename Event_stream<Args...>::Token>
Event_stream<Args...>::subscribe(std::function<void(Args...)> callback)
{
    std::shared_ptr<Token> token(new Token());
    if (auto strongEmitter = emitter.lock()) {
        strongEmitter->subscribers.insert({token.get(), {token, std::move(callback)}});
    }
    return token;
}

template <typename... Args> void Event_emitter<Args...>::emit(Args... args)
{
    for (auto it = begin(subscribers); it != end(subscribers);) {
        const auto locked = it->second.first.lock();
        if (!locked) {
            // note that iterators not pointing to the erased element are not
            // invalidated.
            subscribers.erase(it++);
        } else {
            it->second.second(args...);
            ++it;
        }
    }
}

template <typename... Args>
std::pair<std::shared_ptr<Event_stream<Args...>>, std::shared_ptr<Event_emitter<Args...>>>
make_event()
{
    auto emitter = std::make_shared<Event_emitter<Args...>>();
    auto stream = std::shared_ptr<Event_stream<Args...>>(new Event_stream<Args...>(emitter));
    return std::make_pair(std::move(stream), std::move(emitter));
}
