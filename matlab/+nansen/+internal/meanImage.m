function image = meanImage(stack)
%meanImage The mean over the frames of a height x width x frames nansen.Stack, a chunk of 100 frames at a time
    [height, width, frames] = size(stack);
    total = zeros(height, width);
    for start = 1:100:frames
        total = total + sum(double(stack.frames(start, start + 99)), 3);
    end
    image = total / frames;
end
