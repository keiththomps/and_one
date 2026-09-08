# frozen_string_literal: true

require "test_helper"

class TestSqlNormalization < Minitest::Test
  def test_postgres_golden_queries
    cases = {
      "SELECT * FROM posts WHERE id IN ($1, $2)" => "select * from posts where id in ( ? )",
      "SELECT * FROM posts WHERE id IN (1, 2, 3)" => "select * from posts where id in ( ? )",
      "SELECT 1.25e-3, .5, 12., 0xFF, 0b10" => "select ? , ? , ? , ? , ?",
      "SELECT $1::integer, $2::text" => "select ? :: integer , ? :: text",
      "SELECT 'hello#world', 'a--b', 'c/*d*/e' FROM posts" => "select ? , ? , ? from posts",
      "SELECT 'it''s fine', E'it\\'s fine' FROM posts" => "select ? , ? from posts",
      "SELECT $$hello -- /* # world$$, $tag$it's fine$tag$" => "select ? , ?",
      'SELECT "Title", "a""b", "a--#/*b*/", public."posts" FROM "Posts"' =>
        'select "Title" , "a""b" , "a--#/*b*/" , public . "posts" from "Posts"',
      "SELECT/* outer /* inner */ comment */id FROM posts-- end\nWHERE id=42" => "select id from posts where id = ?",
      "SELECT/*comment*/foo/*comment*/bar" => "select foo bar",
      "SELECT payload #>> '{a,b}', payload ? 'key', payload ?| array['a']" => "select payload #>> ? , payload ? ? , payload ?| array [ ? ]",
      "SELECT * FROM posts WHERE deleted_at IS NULL AND active = TRUE" => "select * from posts where deleted_at is null and active = ?"
    }
    cases.each { |sql, expected| assert_equal expected, normalize(sql, "postgresql"), sql }
  end

  def test_mysql_golden_queries
    cases = {
      "SELECT `posts`.`id` FROM `posts` WHERE id IN (?, ?, ?)" => "select `posts` . `id` from `posts` where id in ( ? )",
      "SELECT 'it\\'s # fine', \"a--b\" FROM posts # comment\nWHERE id=2" => "select ? , ? from posts where id = ?",
      "SELECT `a``b`, `a#--b` FROM posts" => "select `a``b` , `a#--b` from posts",
      "SELECT 2--1" => "select ? - - ?",
      "SELECT 2-- comment\nFROM posts" => "select ? from posts",
      "SELECT /*! STRAIGHT_JOIN */ id FROM posts" => "select /*! STRAIGHT_JOIN */ id from posts",
      "SELECT /*+ MAX_EXECUTION_TIME(1000) */ id FROM posts" => "select /*+ MAX_EXECUTION_TIME(1000) */ id from posts"
    }
    cases.each { |sql, expected| assert_equal expected, normalize(sql, "mysql2"), sql }
    assert_equal "select ?", normalize('SELECT "literal"', "trilogy")
  end

  def test_sqlite_golden_queries
    cases = {
      "SELECT [Title], `a``b`, \"a\"\"b\" FROM [Posts]" => 'select [Title] , `a``b` , "a""b" from [Posts]',
      "SELECT * FROM posts WHERE id IN (?1, :second, @third, $fourth)" => "select * from posts where id in ( ? )",
      "SELECT X'ABCD', 'it''s fine', '\\' FROM posts" => "select ? , ? , ? from posts",
      "SELECT * FROM posts WHERE id IN (SELECT post_id FROM comments)" => "select * from posts where id in ( select post_id from comments )"
    }
    cases.each { |sql, expected| assert_equal expected, normalize(sql, "sqlite3"), sql }
  end

  def test_quoted_identifier_and_structural_distinctions
    pairs = [
      ['SELECT "Title" FROM posts', 'SELECT "title" FROM posts'],
      ['SELECT "a b" FROM posts', 'SELECT "a  b" FROM posts'],
      ['SELECT "a.b" FROM posts', 'SELECT "a"."b" FROM posts'],
      ['SELECT "a" FROM posts', "SELECT a FROM posts"],
      ["SELECT * FROM posts WHERE id = 1", "SELECT * FROM posts WHERE id > 1"],
      ["SELECT * FROM posts WHERE id IS NULL", "SELECT * FROM posts WHERE id IS TRUE"],
      ["SELECT * FROM posts LIMIT 1", "SELECT * FROM posts LIMIT 1 OFFSET 2"],
      ["INSERT INTO posts VALUES (1, 2)", "INSERT INTO posts VALUES (1), (2)"],
      ["SELECT * FROM posts WHERE id IN (1, 2)", "SELECT * FROM posts WHERE id IN (1, other_id)"],
      ["SELECT * FROM posts WHERE id IN (1, 2)", "SELECT * FROM posts WHERE id IN ((1, 2))"]
    ]
    pairs.each { |left, right| refute_equal normalize(left), normalize(right), "#{left} vs #{right}" }
  end

  def test_literal_contents_are_not_rewritten_as_query_structure
    assert_equal "select ?", normalize("SELECT 'IN (1, 2) LIMIT 5 OFFSET 2'")
    assert_equal 'select "IN (1, 2)"', normalize('SELECT "IN (1, 2)"')
    assert_equal "select a # ?", normalize("SELECT a # 2", "postgresql")
  end

  def test_unterminated_constructs_are_preserved_instead_of_silently_removed
    ["SELECT 'unfinished", 'SELECT "unfinished', "SELECT $tag$unfinished", "SELECT /* unfinished"].each do |sql|
      assert_equal sql.sub("SELECT", "select"), normalize(sql)
    end
  end

  def test_large_literals_and_lists
    assert_equal "select ?", normalize("SELECT '#{"a#--/*'".gsub("'", "''") * 10_000}'")
    assert_equal "select * from posts where id in ( ? )", normalize("SELECT * FROM posts WHERE id IN (#{Array.new(10_000, "1").join(",")})")
    assert_equal "select /* #{"x" * 100_000}", normalize("SELECT /* #{"x" * 100_000}")
  end

  def test_deterministic_whitespace_and_literal_invariance
    random = Random.new(42)
    separators = [" ", "\n", "\t", "/**/", " /* comment */ "]
    literals = ["'hello#world'", "'a--b'", "'it''s fine'", "$tag$/* hi */$tag$", "1.2e-3"]
    100.times do
      tokens = ["SELECT", "*", "FROM", "posts", "WHERE", "id", "IN", "(", random.rand(100).to_s,
                ",", random.rand(100).to_s, ")", "AND", "title", "=", literals.sample(random: random)]
      sql = tokens.map { |token| "#{token}#{separators.sample(random: random)}" }.join
      assert_equal "select * from posts where id in ( ? ) and title = ?", normalize(sql, "postgresql")
    end
  end

  def test_does_not_mutate_input
    sql = 'SELECT "Title" FROM posts WHERE id = $1'
    assert_equal 'select "Title" from posts where id = ?', normalize(sql)
    assert_equal 'SELECT "Title" FROM posts WHERE id = $1', sql
  end

  def test_detection_identity_uses_adapter_lexical_rules
    left = AndOne::Detection.new(queries: ['SELECT * FROM posts WHERE title = "first"'], count: 2, adapter: "mysql2")
    right = AndOne::Detection.new(queries: ['SELECT * FROM posts WHERE title = "second"'], count: 2, adapter: "mysql2")
    assert_equal left.fingerprint, right.fingerprint
  end

  private

  def normalize(sql, adapter = nil)
    AndOne::Fingerprint.generate(sql, adapter: adapter)
  end
end
