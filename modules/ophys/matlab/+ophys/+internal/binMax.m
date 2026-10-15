function out = binMax(stack, size_)
%binMax The maximum of each run of size_ frames (one bin of all frames when there are fewer)
    frames = size(stack, 3);
    count = max(1, floor(frames / size_));
    if frames < size_
        size_ = frames;
    end
    out = reshape(max(reshape(stack(:, :, 1:count * size_), size(stack, 1), size(stack, 2), size_, count), [], 3), ...
        size(stack, 1), size(stack, 2), count);
end
