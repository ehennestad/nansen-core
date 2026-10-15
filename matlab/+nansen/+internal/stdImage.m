function image = stdImage(stack)
%stdImage Each pixel's standard deviation over the frames of a height x width x frames nansen.Stack
%
%   The root mean square of its deviations from its mean, a chunk of 100
%   frames at a time, in two passes; as Python's nansen.frames._std.
    [height, width, frames] = size(stack);
    average = nansen.internal.meanImage(stack);
    squares = zeros(height, width);
    for start = 1:100:frames
        squares = squares + sum((double(stack.frames(start, start + 99)) - average) .^ 2, 3);
    end
    image = sqrt(squares / frames);
end
