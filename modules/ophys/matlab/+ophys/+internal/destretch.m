function out = destretch(chunk, plan)
%destretch The frames' lines (dimension 2) as the plan reads them, as Python's destretch
%
%   (1 - w) of the left column and w of the right one; integers rounded
%   half up, in the frames' class.
    shape = size(chunk);
    w = reshape(plan.weight, 1, []);
    flat = reshape(chunk, shape(1), shape(2), []);
    out = double(flat(:, plan.left + 1, :)) .* (1 - w) + double(flat(:, plan.left + 2, :)) .* w;
    if isinteger(chunk)
        out = floor(out + 0.5);
    end
    out = reshape(cast(out, class(chunk)), [shape(1), numel(w), shape(3:end)]);
end
