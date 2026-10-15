function out = gaussianAlong(data, axis, sigma)
%gaussianAlong data smoothed along one axis by a Gaussian of sigma samples, cut at 3 sigma
%
%   At the ends the weights that fall inside are renormalised. Offsets are
%   added from -radius to radius, as in Python.
    count = size(data, axis);
    if sigma <= 0 || count < 2
        out = data;
        return
    end
    radius = ceil(3 * sigma);
    total = zeros(size(data));
    norm = zeros(count, 1);
    index = repmat({':'}, 1, ndims(data));
    other = index;
    for offset = -radius:radius
        weight = exp(-offset * offset / (2 * sigma * sigma));
        here = max(1, 1 - offset):min(count, count - offset);
        if isempty(here)
            continue
        end
        index{axis} = here;
        other{axis} = here + offset;
        total(index{:}) = total(index{:}) + weight * data(other{:});
        norm(here) = norm(here) + weight;
    end
    shape = ones(1, max(ndims(data), axis));
    shape(axis) = count;
    out = total ./ reshape(norm, shape);
end
