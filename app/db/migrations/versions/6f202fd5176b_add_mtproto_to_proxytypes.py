"""add mtproto to proxytypes

Revision ID: 6f202fd5176b
Revises: 2b231de97dc3, e3f0e888a563, ece13c4c6f65
Create Date: 2026-03-20 00:00:00.000000

"""

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = "6f202fd5176b"
down_revision = ("2b231de97dc3", "e3f0e888a563", "ece13c4c6f65")
branch_labels = None
depends_on = None


enum_name = "proxytypes"
temp_enum_name = f"temp_{enum_name}"
old_values = ("VMess", "VLESS", "Trojan", "Shadowsocks")
new_values = (*old_values, "MTProto")
old_type = sa.Enum(*old_values, name=enum_name)
new_type = sa.Enum(*new_values, name=enum_name)
temp_type = sa.Enum(*new_values, name=temp_enum_name)

table_name = "proxies"
column_name = "type"
temp_table = sa.sql.table(
    table_name,
    sa.Column(column_name, new_type, nullable=False),
    sa.Column("settings", sa.JSON(), nullable=False),
)


def upgrade():
    temp_type.create(op.get_bind(), checkfirst=False)

    with op.batch_alter_table(table_name) as batch_op:
        batch_op.alter_column(
            column_name,
            existing_type=old_type,
            type_=temp_type,
            existing_nullable=False,
            postgresql_using=f"{column_name}::text::{temp_enum_name}",
        )

    old_type.drop(op.get_bind(), checkfirst=False)
    new_type.create(op.get_bind(), checkfirst=False)

    with op.batch_alter_table(table_name) as batch_op:
        batch_op.alter_column(
            column_name,
            existing_type=temp_type,
            type_=new_type,
            existing_nullable=False,
            postgresql_using=f"{column_name}::text::{enum_name}",
        )

    temp_type.drop(op.get_bind(), checkfirst=False)


def downgrade():
    op.execute(
        temp_table
        .update()
        .where(temp_table.c.type == "MTProto")
        .values(type="Shadowsocks", settings={})
    )

    temp_type.create(op.get_bind(), checkfirst=False)

    with op.batch_alter_table(table_name) as batch_op:
        batch_op.alter_column(
            column_name,
            existing_type=new_type,
            type_=temp_type,
            existing_nullable=False,
            postgresql_using=f"{column_name}::text::{temp_enum_name}",
        )

    new_type.drop(op.get_bind(), checkfirst=False)
    old_type.create(op.get_bind(), checkfirst=False)

    with op.batch_alter_table(table_name) as batch_op:
        batch_op.alter_column(
            column_name,
            existing_type=temp_type,
            type_=old_type,
            existing_nullable=False,
            postgresql_using=f"{column_name}::text::{enum_name}",
        )

    temp_type.drop(op.get_bind(), checkfirst=False)
