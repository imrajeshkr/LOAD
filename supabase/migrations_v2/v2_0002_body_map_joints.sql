-- =============================================================================
-- LOAD v2 — body-map joints
--
-- The v2 onboarding body map has front and back views with left/right-specific
-- nodes. The v1 joint list covers the front reasonably but has nothing for the
-- back view (upper back, shoulder blades, glutes, hamstrings, calves) and no
-- neck.
--
-- Laterality is NOT stored here: user_constraints.side already carries
-- left/right/bilateral, so "L shoulder" is (joint=shoulder, side=left) rather
-- than two separate joint rows. That keeps exercise_joints — which is about
-- which joints a movement stresses, a fact with no sidedness — unchanged.
-- =============================================================================

insert into joints (slug, name) values
  ('neck',           'Neck'),
  ('upper-back',     'Upper Back'),
  ('shoulder-blade', 'Shoulder Blade'),
  ('glute',          'Glute'),
  ('hamstring',      'Hamstring'),
  ('calf',           'Calf')
on conflict (slug) do nothing;

-- The body map needs to know where to draw each node and on which view.
-- Coordinates are fractions of the silhouette box (0..1 from top-left) so the
-- client can scale the map to any width without a lookup table in Dart.
alter table joints
  add column if not exists map_view text check (map_view in ('front', 'back', 'both')),
  add column if not exists map_x numeric(4,3) check (map_x between 0 and 1),
  add column if not exists map_y numeric(4,3) check (map_y between 0 and 1),
  add column if not exists is_lateral boolean not null default false;

comment on column joints.is_lateral is
  'True when the map shows separate left and right nodes for this joint, so the '
  'client knows to emit user_constraints.side. Neck and lower back are midline.';

comment on column joints.map_x is
  'Horizontal position as a fraction of the silhouette width. For lateral joints '
  'this is the RIGHT-side node; the left node mirrors to (1 - map_x).';

-- Front view.
update joints set map_view='front', map_x=0.685, map_y=0.205, is_lateral=true  where slug='shoulder';
update joints set map_view='front', map_x=0.735, map_y=0.330, is_lateral=true  where slug='elbow';
update joints set map_view='front', map_x=0.775, map_y=0.440, is_lateral=true  where slug='wrist';
update joints set map_view='both',  map_x=0.500, map_y=0.115, is_lateral=false where slug='neck';
update joints set map_view='front', map_x=0.500, map_y=0.480, is_lateral=false where slug='hip';
update joints set map_view='front', map_x=0.605, map_y=0.660, is_lateral=true  where slug='knee';
update joints set map_view='front', map_x=0.610, map_y=0.860, is_lateral=true  where slug='ankle';

-- Back view.
update joints set map_view='back',  map_x=0.500, map_y=0.250, is_lateral=false where slug='upper-back';
update joints set map_view='back',  map_x=0.500, map_y=0.395, is_lateral=false where slug='lumbar';
update joints set map_view='back',  map_x=0.650, map_y=0.225, is_lateral=true  where slug='shoulder-blade';
update joints set map_view='back',  map_x=0.615, map_y=0.510, is_lateral=true  where slug='glute';
update joints set map_view='back',  map_x=0.610, map_y=0.665, is_lateral=true  where slug='hamstring';
update joints set map_view='back',  map_x=0.605, map_y=0.815, is_lateral=true  where slug='calf';
