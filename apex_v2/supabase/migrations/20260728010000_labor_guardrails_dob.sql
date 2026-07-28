-- Labor guardrails: optional DOB for minor-hour checks (plan #9).
alter table profiles
  add column if not exists date_of_birth date;

comment on column profiles.date_of_birth is
  'Optional. Used only for minor labor-hour warnings; never shown to other staff.';
