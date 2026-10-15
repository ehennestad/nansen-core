function aligned = applyShifts(stack, shifts)
%applyShifts Each frame moved back by its shift: out(y, x) = frame(y + dy, x + dx), and 0 outside the frame
    [height, width, frames] = size(stack);
    aligned = zeros(size(stack), "like", stack);
    for t = 1:frames
        dy = double(shifts(t, 1));
        dx = double(shifts(t, 2));
        aligned(max(1, 1 - dy):min(height, height - dy), max(1, 1 - dx):min(width, width - dx), t) = ...
            stack(max(1, 1 + dy):min(height, height + dy), max(1, 1 + dx):min(width, width + dx), t);
    end
end
