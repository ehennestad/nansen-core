function [names, values] = xmlAttributes(tag)
%xmlAttributes The name="value" attributes of an XML tag, as string arrays in their order
    pairs = regexp(char(tag), '(\w+)="([^"]*)"', "tokens");
    names = strings(1, numel(pairs));
    values = strings(1, numel(pairs));
    for i = 1:numel(pairs)
        names(i) = pairs{i}{1};
        values(i) = pairs{i}{2};
    end
end
