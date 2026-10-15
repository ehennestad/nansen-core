function range = shiftRange(centre, deviation, maxShift, half)
%shiftRange The whole-pixel shifts within deviation of centre, maxShift of 0 and half the size of the frame
    limit = min(maxShift, half);
    range = max(centre - deviation, -limit):min(centre + deviation, limit);
end
