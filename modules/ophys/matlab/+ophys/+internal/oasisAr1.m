function [calcium, spikes] = oasisAr1(y, g, lambda)
%oasisAr1 Denoised calcium and spikes minimising 1/2 |c - y|^2 + lambda * sum(s), s_t = c_t - g c_(t-1) >= 0, c_1 = s_1 >= 0
%
%   Pools of frames share one exponential decay; a pool whose start would
%   need a negative spike is merged with the one before (pool adjacent
%   violators), as Python's oasis_ar1 does, step for step.
    y = y(:);
    frames = numel(y);
    powers = cumprod([1; repmat(g, 2 * frames, 1)]);   % powers(k + 1) = g^k
    target = y - lambda * (1 - g);
    target(end) = y(end) - lambda;
    values = zeros(frames, 1);
    weights = zeros(frames, 1);
    starts = zeros(frames, 1);
    lengths = zeros(frames, 1);
    n = 0;
    for t = 1:frames
        n = n + 1;
        values(n) = target(t);
        weights(n) = 1;
        starts(n) = t;
        lengths(n) = 1;
        while n > 1
            previous = values(n - 1);
            if n == 2
                previous = max(previous, 0);   % c_1 >= 0
            end
            if values(n) >= powers(lengths(n - 1) + 1) * previous
                break
            end
            span = lengths(n - 1);
            weight = weights(n - 1) + weights(n) * powers(2 * span + 1);
            values(n - 1) = (values(n - 1) * weights(n - 1) + values(n) * weights(n) * powers(span + 1)) / weight;
            weights(n - 1) = weight;
            lengths(n - 1) = span + lengths(n);
            n = n - 1;
        end
    end
    calcium = zeros(frames, 1);
    for j = 1:n
        calcium(starts(j):starts(j) + lengths(j) - 1) = max(values(j), 0) * powers(1:lengths(j));
    end
    spikes = calcium;
    spikes(2:end) = calcium(2:end) - g * calcium(1:end - 1);
end
