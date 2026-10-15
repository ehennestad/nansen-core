function [binned, average] = binnedMax(stack, size_, wantAverage)
%binnedMax binMax of a nansen.Stack read a chunk of whole bins at a time; and, when asked, the mean of every frame
%
%   As Python's binned_max.
    [height, width, frames] = size(stack);
    if frames < size_
        size_ = frames;
    end
    count = max(1, floor(frames / size_));
    binned = zeros(height, width, count);
    total = zeros(height, width);
    step = size_ * max(1, floor(ophys.internal.chunk() / size_));
    last = count * size_;
    if wantAverage
        last = frames;
    end
    for start = 0:step:last - 1   % 0-based, as in Python
        chunk = double(stack.frames(start + 1, min(start + step, frames)));
        whole = 0;
        if start < count * size_
            whole = floor(min(size(chunk, 3), count * size_ - start) / size_) * size_;
        end
        if whole > 0
            binned(:, :, start / size_ + (1:whole / size_)) = reshape(max(reshape(chunk(:, :, 1:whole), height, width, size_, whole / size_), [], 3), ...
                height, width, whole / size_);
        end
        if wantAverage
            total = total + sum(chunk, 3);
        end
    end
    average = [];
    if wantAverage
        average = total / frames;
    end
end
