function stack = openStack(context, entity, name, options)
%openStack The variable as a height x width x frames nansen.Stack read a chunk at a time (an image is one frame)
%
%   A stack with channels (height x width x channels x frames) or planes too
%   (x channels x planes x frames) gives the options' channel and plane
%   (1-based; the first when there is no such option).
    if nargin < 4
        options = struct();
    end
    stack = context.Project.openStack(entity, name);
    if ndims(stack) == 2
        limit = stack.MaxFrames;
        stack.MaxFrames = Inf;   % an image's columns are not frames
        stack = nansen.Stack.fromArray(stack.all(), 3);   % an image: one frame
        stack.MaxFrames = limit;
    end
    stack = ophys.internal.pick(stack, name, double(nansen.internal.getField(options, "channel", 1)), ...
        double(nansen.internal.getField(options, "plane", 1)));
end
