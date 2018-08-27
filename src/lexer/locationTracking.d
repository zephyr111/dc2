module lexer.locationTracking;

import std.stdio;
import std.range;
import std.range.primitives;
import std.traits;


// Lazy range: consume not more char than requested
// Cannot take an InputRange as input due to look-ahead parsing
struct LocationTracking(Range)
{
    private
    {
        alias This = typeof(this);

        Range _input;
        string _filename;
        uint _line = 1;
        uint _col = 1;
        ulong _pos = 0;
    }


    this(Range input, string filename)
    {
        _input = input;
        _filename = filename;
    }

    @property bool empty()
    {
        return _input.empty;
    }

    @property auto front()
    {
        return _input.front;
    }

    void popFront()
    {
        auto first = _input.front;
        _input.popFront();
        _col++;
        _pos++;

        if(first == '\n')
        {
            _line++;
            _col = 1;
        }
    }

    @property auto save()
    {
        This result = this;
        result._input = _input.save;
        return result;
    }

    @property auto filename() const { return _filename; }
    @property auto line() const { return _line; }
    @property auto col() const { return _col; }
    @property auto pos() const { return _pos; }
}

LocationTracking!Range trackLocation(Range)(Range input, string filename)
    if(isForwardRange!Range && isSomeChar!(ElementEncodingType!Range) && !isConvertibleToString!Range)
{
    return LocationTracking!Range(input, filename);
}


