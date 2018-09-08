/* Copyright (c) 2018 <Jérôme Richard>
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module lexer.trigraphSubstitution;

import std.stdio;
import std.range;
import std.range.primitives;
import std.traits;
import std.algorithm.comparison;
import std.algorithm.searching;
import std.string;
import utils;


// Lazy range: consume not more char than requested
// Cannot take an InputRange as input due to look-ahead parsing
struct TrigraphSubstitution(Range)
{
    private
    {
        alias This = typeof(this);

        Range _input;
    }


    this(Range input)
    {
        _input = input;
    }

    @property bool empty()
    {
        return _input.empty;
    }

    @property auto front()
    {
        auto first = _input.front;

        if(first == '?')
        {
            auto lookAhead = _input.save.dropOne;

            if(lookAhead.skipIf('?') && !lookAhead.empty)
            {
                const long pos = "=/'()!<>-".indexOf(lookAhead.front);

                if(pos >= 0)
                    return "#\\^[]|{}~"[pos];
            }
        }

        return first;
    }

    void popFront()
    {
        auto first = _input.front;
        _input.popFront();

        if(first == '?' && _input.startsWith('?'))
        {
            auto lookAhead = _input.save.dropOne;

            if(!lookAhead.empty && "=/'()!<>-".canFind(lookAhead.front))
                _input = lookAhead.dropOne;
        }
    }

    @property auto save()
    {
        return This(_input.save);
    }

    @property auto filename() const { return _input.filename; }
    @property auto line() const { return _input.line; }
    @property auto col() const { return _input.col; }
    @property auto pos() const { return _input.pos; }
}

TrigraphSubstitution!Range substituteTrigraph(Range)(Range input)
    if(isForwardRange!Range && isSomeChar!(ElementEncodingType!Range) && !isConvertibleToString!Range)
{
    return TrigraphSubstitution!Range(input);
}


