function [calcium, spikes] = oasisAr2(y, d, r, lambda)
%oasisAr2 Denoised calcium and spikes of OASIS for an AR(2) model, s_t = c_t - g1 c_(t-1) - g2 c_(t-2) >= 0
%
%   g1 = d + r and g2 = -d r (decay d >= rise r), towards the minimum of
%   1/2 |c - y|^2 + lambda * sum(s). The calcium before the first spike
%   decays by d from c_1 >= 0; a pool of frames without spikes follows the
%   kernel h_k = (d^(k+1) - r^(k+1)) / (d - r) from its first value and the
%   last value of the pool before it, and a pool whose first value is
%   below what the pool before would continue to is merged with it
%   (greedy, as AR(2) in OASIS). As Python's oasis_ar2, step for step.
    y = y(:);
    frames = numel(y);
    g1 = d + r;
    g2 = -d * r;
    dpow = cumprod([1; repmat(d, frames + 1, 1)]);   % dpow(k + 1) = d^k
    rpow = cumprod([1; repmat(r, frames + 1, 1)]);
    if d == r
        h = (1:frames + 1)' .* dpow(1:frames + 1);
    else
        h = (dpow(2:end) - rpow(2:end)) / (d - r);   % h(k + 1) = h_k
    end
    g12 = [0; g2 * h(1:end - 1)];
    hh = cumsum(h .* h);
    hg = cumsum(h .* g12);
    dd = cumsum(dpow(1:frames) .* dpow(1:frames));
    weight = ones(frames, 1);   % each c_t's weight in sum(s)
    if frames >= 3
        weight(2:frames - 2) = 1 - g1 - g2;
        weight(1) = 1 - d - g2;
        weight(frames - 1) = 1 - g1;
    elseif frames == 2
        weight(1) = 1 - d;
    end
    target = y - lambda * weight;
    values = zeros(frames, 1);
    lasts = zeros(frames, 1);
    starts = zeros(frames, 1);
    lengths = zeros(frames, 1);
    sums = zeros(frames, 1);   % of each frame's target times its kernel value
    n = 0;
    for t = 1:frames
        n = n + 1;
        if n == 1
            values(n) = max(target(t), 0);   % c_1 >= 0
        else
            values(n) = target(t);
        end
        lasts(n) = values(n);
        starts(n) = t;
        lengths(n) = 1;
        sums(n) = target(t);
        while n > 1
            span = lengths(n - 1);
            if n == 2   % what the first pool decays to next
                expected = lasts(1) * d;
            else
                expected = h(span + 1) * values(n - 1) + g12(span + 1) * lasts(n - 2);
            end
            if values(n) >= expected
                break
            end
            total = sums(n - 1);
            for j = 0:lengths(n) - 1
                if n == 2
                    total = total + dpow(span + j + 1) * target(starts(n) + j);
                else
                    total = total + h(span + j + 1) * target(starts(n) + j);
                end
            end
            merged = span + lengths(n);
            n = n - 1;
            sums(n) = total;
            lengths(n) = merged;
            if n == 1
                values(n) = max(total / dd(merged), 0);
                lasts(n) = dpow(merged) * values(n);
            else
                values(n) = (total - hg(merged) * lasts(n - 1)) / hh(merged);
                lasts(n) = h(merged) * values(n) + g12(merged) * lasts(n - 1);
            end
        end
    end
    calcium = zeros(frames, 1);
    for i = 1:n
        span = starts(i):starts(i) + lengths(i) - 1;
        if i == 1
            calcium(span) = values(i) * dpow(1:lengths(i));
        else
            calcium(span) = h(1:lengths(i)) * values(i) + g12(1:lengths(i)) * lasts(i - 1);
        end
    end
    spikes = calcium;
    if frames > 1
        spikes(2) = calcium(2) - d * calcium(1);
        spikes(3:end) = calcium(3:end) - g1 * calcium(2:end - 1) - g2 * calcium(1:end - 2);
    end
end
