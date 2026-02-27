# frozen_string_literal: true

require "test_helper"

class TestFingerprint < Minitest::Test
  def test_same_query_different_values
    q1 = %(SELECT "posts".* FROM "posts" WHERE "posts"."author_id" = 1)
    q2 = %(SELECT "posts".* FROM "posts" WHERE "posts"."author_id" = 42)

    assert_equal AndOne::Fingerprint.generate(q1), AndOne::Fingerprint.generate(q2)
  end

  def test_different_queries
    q1 = %(SELECT "posts".* FROM "posts" WHERE "posts"."author_id" = 1)
    q2 = %(SELECT "comments".* FROM "comments" WHERE "comments"."post_id" = 1)

    refute_equal AndOne::Fingerprint.generate(q1), AndOne::Fingerprint.generate(q2)
  end

  def test_normalizes_in_lists
    q1 = %{SELECT * FROM posts WHERE id IN (1, 2, 3)}
    q2 = %{SELECT * FROM posts WHERE id IN (4, 5, 6, 7, 8)}

    assert_equal AndOne::Fingerprint.generate(q1), AndOne::Fingerprint.generate(q2)
  end

  def test_normalizes_strings
    q1 = %(SELECT * FROM posts WHERE title = 'Hello World')
    q2 = %(SELECT * FROM posts WHERE title = 'Goodbye World')

    assert_equal AndOne::Fingerprint.generate(q1), AndOne::Fingerprint.generate(q2)
  end

  def test_normalizes_pg_placeholders
    q1 = %(SELECT * FROM posts WHERE id = $1 AND author_id = $2)
    q2 = %(SELECT * FROM posts WHERE id = $3 AND author_id = $4)

    assert_equal AndOne::Fingerprint.generate(q1), AndOne::Fingerprint.generate(q2)
  end

  def test_normalizes_whitespace
    q1 = %(SELECT  *   FROM   posts   WHERE   id = 1)
    q2 = %(SELECT * FROM posts WHERE id = 2)

    assert_equal AndOne::Fingerprint.generate(q1), AndOne::Fingerprint.generate(q2)
  end

  def test_normalizes_booleans
    q1 = %(SELECT * FROM posts WHERE active = TRUE)
    q2 = %(SELECT * FROM posts WHERE active = FALSE)

    assert_equal AndOne::Fingerprint.generate(q1), AndOne::Fingerprint.generate(q2)
  end
end
