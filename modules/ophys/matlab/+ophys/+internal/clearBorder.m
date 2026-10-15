function out = clearBorder(mask)
%clearBorder Foreground areas (8-connected) that touch the border removed
    [height, width] = size(mask);
    out = mask;
    for area = ophys.internal.components(mask, 8)
        pixels = area{1};
        if any(pixels(:, 1) == 1 | pixels(:, 1) == height | pixels(:, 2) == 1 | pixels(:, 2) == width)
            out(sub2ind([height, width], pixels(:, 1), pixels(:, 2))) = false;
        end
    end
end
