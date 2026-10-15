function image = globalCorrelation(stack)
%globalCorrelation Each pixel's Pearson correlation over time with the mean of the whole frame
%
%   dev's globalCorrelation projection. stack is an array or a
%   nansen.Stack, read a chunk of frames at a time in two passes: each
%   pixel's mean and the frames' means, then the sums over time of its
%   deviations squared and times the frame mean's deviations. A pixel that
%   does not change correlates 0. As Python's nansen.frames.global_correlation.
    if ~isa(stack, "nansen.Stack")
        stack = nansen.Stack.fromArray(stack, 3);
    end
    [height, width, frames] = size(stack);
    chunk = 100;   % frames read at a time
    total = zeros(height, width);
    signal = zeros(1, 1, frames);
    for first = 1:chunk:frames
        last = min(first + chunk - 1, frames);
        data = double(stack.frames(first, last));
        total = total + sum(data, 3);
        signal(first:last) = sum(data, [1, 2]) / (height * width);
    end
    average = total / frames;
    signal = signal - sum(signal) / frames;
    squares = zeros(height, width);
    products = zeros(height, width);
    for first = 1:chunk:frames
        last = min(first + chunk - 1, frames);
        deviation = double(stack.frames(first, last)) - average;
        squares = squares + sum(deviation .^ 2, 3);
        products = products + sum(deviation .* signal(1, 1, first:last), 3);
    end
    spread = sqrt(squares * sum(signal .^ 2));
    image = products ./ spread;
    image(~(spread > 0)) = 0;
end
