#include "ConcurrentQueue.h"

namespace tns {

std::string ConcurrentQueue::Pop() {
    std::unique_lock<std::mutex> mlock(this->mutex_);
    while (this->queue_.empty()) {
        this->conditionVar_.wait(mlock);
        if (this->isTerminating_) {
            return "";
        }
    }
    auto val = this->queue_.front();
    this->queue_.pop();
    return val;
}

void ConcurrentQueue::Push(const std::string& item) {
    std::unique_lock<std::mutex> mlock(this->mutex_);
    this->queue_.push(item);
    mlock.unlock();
    this->conditionVar_.notify_one();
}

void ConcurrentQueue::Notify() {
    this->isTerminating_ = true;
    this->conditionVar_.notify_one();
}

}
