function out = shiftedMask(mask, dy, dx, fill)
%shiftedMask mask moved so that out(y, x) = mask(y + dy, x + dx), fill outside
    [height, width] = size(mask);
    out = repmat(fill, height, width);
    out(max(1, 1 - dy):min(height, height - dy), max(1, 1 - dx):min(width, width - dx)) = ...
        mask(max(1, 1 + dy):min(height, height + dy), max(1, 1 + dx):min(width, width + dx));
end
