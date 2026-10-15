function [whole, stacks, every] = planeStacks(context, entity, name, options)
%planeStacks The stack of all its axes, the planes' stacks to take, and whether they are every plane
%
%   whole is ophys.internal.openWhole's stack; stacks a cell array of the
%   height x width x frames stacks of the options' channel in the planes to
%   take: with plane 0, every plane of a stack with planes (height x width x
%   channels x planes x frames), one after the other (every is true); else
%   the options' plane (a stack without planes is one plane). As Python's
%   _plane_stacks.
    whole = ophys.internal.openWhole(context, entity, name, options);
    channel = double(nansen.internal.getField(options, "channel", 1));
    plane = double(nansen.internal.getField(options, "plane", 1));
    every = plane == 0 && ndims(whole) == 5;
    if every
        stacks = cell(1, size(whole, 4));
        for p = 1:numel(stacks)
            stacks{p} = ophys.internal.pick(whole, name, channel, p);
        end
        return
    end
    if plane == 0
        plane = 1;
    end
    stacks = {ophys.internal.pick(whole, name, channel, plane)};
end
