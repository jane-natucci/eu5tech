# The parser for Paradox's Jomini script format, shared by the extractors.

# Just enough of a parser for Paradox's Jomini script format: `key = value`,
# `key ?= { ... }`, comparisons, bare list items and # comments. A block is
# an array of [key, op, value] entries; bare list items have a nil key.
module Jomini
  TOKEN = /\s+|#[^\n]*|"(?:[^"\\]|\\.)*"|[?!<>=]=|[={}<>]|[^\s={}<>#"]+/

  def self.parse(text)
    tokens = text.delete_prefix("﻿").scan(TOKEN).reject { |t| t.match?(/\A\s/) || t.start_with?("#") }
    block, = parse_block(tokens, 0)
    block
  end

  def self.parse_block(tokens, i)
    entries = []
    while i < tokens.size && tokens[i] != "}"
      first = tokens[i]
      if tokens[i + 1]&.match?(/\A(?:[?!<>=]=|[=<>])\z/)
        op = tokens[i + 1]
        value, i = parse_value(tokens, i + 2)
        entries << [unquote(first), op, value]
      else
        value, i = parse_value(tokens, i)
        entries << [nil, nil, value]
      end
    end
    [entries, i + 1]
  end

  def self.parse_value(tokens, i)
    return parse_block(tokens, i + 1) if tokens[i] == "{"
    [unquote(tokens[i]), i + 1]
  end

  def self.unquote(token) = token.delete_prefix('"').delete_suffix('"')

  def self.values(block, key) = block.select { |k, _, _| k == key }.map(&:last)
  def self.value(block, key) = values(block, key).first
  def self.blocks(block) = block.select { |k, _, v| k && v.is_a?(Array) }.map { |k, _, v| [k, v] }

  # Every [key, value] at any depth.
  def self.walk(block, &visit)
    block.each do |k, _, v|
      visit.call(k, v)
      walk(v, &visit) if v.is_a?(Array)
    end
  end
end
