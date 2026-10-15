function value = roundTo(value, digits)
%roundTo Rounded to digits decimals, half away from zero in the scaled value, as round_to in Python
%
%   NaN stays NaN (null in JSON).
    scale = 10 ^ digits;
    value = floor(double(value) * scale + 0.5) / scale;
end
