function tf = versionLess(a, b)
%versionLess Whether version vector a sorts before b, comparing element by element
    difference = find(a ~= b, 1);
    tf = ~isempty(difference) && a(difference) < b(difference);
end
