function plan = destretchPlan(displacement)
%destretchPlan For each column of the corrected line, the raw column left of where it comes from and the weight of the one right of it
%
%   As Python's destretch_plan: raw column c (from 0) lands at
%   c - displacement(c + 1); the corrected line is the whole positions from
%   the first raw column's to the last's, each read from the raw line by
%   linear interpolation at the inverse of that map. plan.left is from 0.
    width = numel(displacement);
    position = (0:width - 1) - reshape(displacement, 1, []);
    if ~all(diff(position) > 0)
        nansen.internal.throwError("invalid-data", "the stretch profile does not keep the columns in order")
    end
    targets = ceil(position(1)):floor(position(end));
    c = zeros(1, numel(targets));
    k = 1;   % position(k) <= target, the last such (targets rise)
    for i = 1:numel(targets)
        while k < width && position(k + 1) <= targets(i)
            k = k + 1;
        end
        c(i) = k - 1;
    end
    c = min(max(c, 0), width - 2);
    source = c + (targets - position(c + 1)) ./ (position(c + 2) - position(c + 1));
    left = min(max(floor(source), 0), width - 2);
    plan = struct("left", left, "weight", source - left);
end
