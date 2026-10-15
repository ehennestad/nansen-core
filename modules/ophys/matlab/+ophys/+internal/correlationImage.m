function image = correlationImage(stack)
%correlationImage Each pixel's average Pearson correlation with its in-frame 8 neighbours over time
%
%   stack is an array or a nansen.Stack, read a chunk of frames at a time
%   in three passes: each pixel's mean, its spread (the root mean square of
%   its deviations from the mean), and the sums over time of its normalised
%   deviations times each neighbour's; as Python's correlation_image.
    if ~isa(stack, "nansen.Stack")
        stack = nansen.Stack.fromArray(stack, 3);
    end
    [height, width, frames] = size(stack);
    chunk = ophys.internal.chunk();
    total = zeros(height, width);
    for first = 1:chunk:frames
        total = total + sum(double(stack.frames(first, min(first + chunk - 1, frames))), 3);
    end
    average = total / frames;
    squares = zeros(height, width);
    for first = 1:chunk:frames
        squares = squares + sum((double(stack.frames(first, min(first + chunk - 1, frames))) - average) .^ 2, 3);
    end
    spread = sqrt(squares / frames);
    offsets = [-1, -1; -1, 0; -1, 1; 0, -1; 0, 1; 1, -1; 1, 0; 1, 1];   % as Python's, row by row
    products = repmat({zeros(height, width)}, 1, 8);
    for first = 1:chunk:frames
        data = (double(stack.frames(first, min(first + chunk - 1, frames))) - average) ./ spread;
        data(isnan(data) | isinf(data)) = 0;   % a pixel that does not change
        for k = 1:8
            [hereRows, hereColumns, thereRows, thereColumns] = spans(offsets(k, :), height, width);
            products{k}(hereRows, hereColumns) = products{k}(hereRows, hereColumns) + ...
                sum(data(hereRows, hereColumns, :) .* data(thereRows, thereColumns, :), 3);
        end
    end
    total = zeros(height, width);
    count = zeros(height, width);
    for k = 1:8
        [hereRows, hereColumns] = spans(offsets(k, :), height, width);
        total(hereRows, hereColumns) = total(hereRows, hereColumns) + products{k}(hereRows, hereColumns) / frames;
        count(hereRows, hereColumns) = count(hereRows, hereColumns) + 1;
    end
    image = total ./ count;
    image(count == 0) = 0;
end

function [hereRows, hereColumns, thereRows, thereColumns] = spans(offset, height, width)
    dy = offset(1);
    dx = offset(2);
    hereRows = max(1, 1 - dy):min(height, height - dy);
    hereColumns = max(1, 1 - dx):min(width, width - dx);
    thereRows = max(1, 1 + dy):min(height, height + dy);
    thereColumns = max(1, 1 + dx):min(width, width + dx);
end
